//! Local paint state for an owner interaction. No transcript, cursor or provider I/O.
use crate::{
    cli::generate_request_id,
    client::{ClientError, DaemonClient, LoginOperation, LoginState},
};
use std::{
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant},
};

const VERIFY: &str = "https://auth.openai.com/codex/device";
const MAX_LIFETIME: Duration = Duration::from_secs(15 * 60 + 15);

enum Update {
    Operation(LoginOperation),
    Failed(&'static str),
}

pub(super) struct Login {
    source: String,
    operation: Option<String>,
    code: Option<String>,
    deadline: Instant,
    poll_at: Instant,
    in_flight: Option<Receiver<Update>>,
    cancelling: bool,
    done: Option<&'static str>,
}

pub(crate) fn source_id(id: &str) -> bool {
    id.len() <= 32
        && id.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

impl Login {
    pub fn start(client: DaemonClient, source: String) -> Self {
        let mut flow = Self {
            source: source.clone(),
            operation: None,
            code: None,
            deadline: Instant::now() + MAX_LIFETIME,
            poll_at: Instant::now(),
            in_flight: None,
            cancelling: false,
            done: None,
        };
        let id = generate_request_id();
        flow.spawn(move || {
            // Retry only an ambiguous startup with the same idempotency key.
            let result = match client.start_login("openai_codex", &source, &id) {
                Err(ClientError::Io(_)) => client.start_login("openai_codex", &source, &id),
                result => result,
            };
            result.map(Update::Operation).unwrap_or_else(|e| Update::Failed(match e {
                ClientError::HttpStatus { status: 404, .. } => "Device login is not enabled on this daemon. See docs/providers.md.",
                ClientError::HttpStatus { status: 409, .. } => "Another login or refresh is already in progress.",
                ClientError::HttpStatus { status: 422, .. } => "Invalid Codex alias or account limit reached.",
                ClientError::HttpStatus { status: 429, .. } => "Too many login attempts. Wait and try again.",
                _ => "Could not confirm login start. The daemon may still have a pending operation.",
            }))
        });
        flow
    }

    pub fn is_done(&self) -> bool {
        self.done.is_some()
    }

    pub fn cancel(&mut self) -> bool {
        if self.done.is_some() {
            return true;
        }
        self.cancelling = true;
        self.code = None;
        false
    }

    pub fn tick(&mut self, client: &DaemonClient) -> bool {
        if self.done.is_some() {
            return false;
        }
        let mut repaint = false;
        if let Some(rx) = &self.in_flight {
            let update = match rx.try_recv() {
                Ok(update) => update,
                Err(TryRecvError::Empty) if Instant::now() < self.deadline => return false,
                Err(TryRecvError::Empty) => {
                    Update::Failed("Login deadline reached. Check source status with /login.")
                }
                Err(TryRecvError::Disconnected) => {
                    Update::Failed("Login worker stopped. Check source status with /login.")
                }
            };
            self.in_flight = None;
            match update {
                Update::Operation(response) => self.apply(response),
                Update::Failed(message) => self.finish(message),
            }
            repaint = true;
        }
        if self.done.is_some() {
            return repaint;
        }
        if Instant::now() >= self.deadline {
            self.finish("Login deadline reached. Check source status with /login.");
            return true;
        }
        if let Some(reference) = self.operation.clone() {
            let client = client.clone();
            if self.cancelling {
                self.spawn(move || {
                    client
                        .cancel_login(&reference)
                        .ok()
                        .filter(|result| {
                            !matches!(result.state, LoginState::Starting | LoginState::Pending)
                        })
                        .map(Update::Operation)
                        .unwrap_or(Update::Failed(
                            "Cancellation not confirmed. Check source status with /login.",
                        ))
                });
            } else if Instant::now() >= self.poll_at {
                self.spawn(move || {
                    client
                        .login_status(&reference)
                        .map(Update::Operation)
                        .unwrap_or(Update::Failed(
                            "Lost login status. The daemon may still be processing it.",
                        ))
                });
            }
        }
        repaint
    }

    pub fn lines(&self) -> Vec<String> {
        let title = format!("Codex sign-in · {}", self.source);
        if let Some(message) = self.done {
            return vec![title, message.into(), "Esc or Enter to close".into()];
        }
        if self.cancelling {
            return vec![
                title,
                "Waiting for the daemon to confirm cancellation…".into(),
            ];
        }
        match self.code.as_ref() {
            Some(code) => vec![
                title,
                format!("Open {VERIFY}"),
                format!("Enter code: {code}"),
                "Approve only the login you initiated. Esc to cancel.".into(),
            ],
            None => vec![title, "Waiting for Codex sign-in… Esc to cancel.".into()],
        }
    }

    fn spawn(&mut self, f: impl FnOnce() -> Update + Send + 'static) {
        let (tx, rx) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let _ = tx.send(f());
        });
        self.in_flight = Some(rx);
    }

    fn finish(&mut self, message: &'static str) {
        self.code = None;
        self.operation = None;
        self.done = Some(message);
    }

    fn apply(&mut self, response: LoginOperation) {
        let valid_ref = response.operation.len() == 43
            && response
                .operation
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !valid_ref
            || response.source != self.source
            || self
                .operation
                .as_ref()
                .is_some_and(|id| id != &response.operation)
        {
            self.finish("Invalid daemon login response.");
            return;
        }
        match response.state {
            LoginState::Starting | LoginState::Pending => {
                self.operation = Some(response.operation);
                self.poll_at = Instant::now()
                    + Duration::from_millis(
                        response.poll_after_ms.unwrap_or(1000).clamp(500, 5000),
                    );
                // Leave a small buffer to receive the daemon's terminal expiry status.
                if let Some(ms) = response.expires_in_ms {
                    self.deadline = self
                        .deadline
                        .min(Instant::now() + Duration::from_millis(ms.min(900_000) + 3000));
                }
                self.code = match (response.verification_url.as_deref(), response.user_code) {
                    (None, None) => None,
                    (Some(VERIFY), Some(code))
                        if (4..=24).contains(&code.len())
                            && code.bytes().all(|b| {
                                b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'-'
                            }) =>
                    {
                        Some(code)
                    }
                    _ => {
                        self.finish("Invalid verification instructions from daemon.");
                        None
                    }
                };
            }
            LoginState::Complete => self.finish("Signed in. Choose a Codex model with /model."),
            LoginState::Cancelled => self.finish("Login cancelled."),
            LoginState::Expired => self.finish("Login expired. Run /login again."),
            LoginState::Failed => self.finish(match response.reason.as_deref() {
                Some("device_auth_unavailable") => {
                    "Device login unavailable. Check your ChatGPT settings and workspace policy."
                }
                Some("identity_mismatch") => {
                    "That account differs from the one already bound to this source."
                }
                Some("identity_already_configured") => {
                    "That account is already bound to another source."
                }
                Some("credential_store_unavailable") => "The daemon could not save the credential.",
                Some("access_denied") => "Account authorization was denied.",
                _ => "Codex sign-in failed. No credential was installed.",
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flow() -> Login {
        Login {
            source: "personal".into(),
            operation: None,
            code: None,
            deadline: Instant::now() + MAX_LIFETIME,
            poll_at: Instant::now(),
            in_flight: None,
            cancelling: false,
            done: None,
        }
    }

    fn pending() -> LoginOperation {
        LoginOperation {
            operation: "x".repeat(43),
            source: "personal".into(),
            state: LoginState::Pending,
            verification_url: Some(VERIFY.into()),
            user_code: Some("ABCD-1234".into()),
            expires_in_ms: Some(20_000),
            poll_after_ms: Some(1000),
            reason: None,
        }
    }

    #[test]
    fn rejects_stale_operation_and_hides_code_on_terminal_state() {
        let mut login = flow();
        login.apply(pending());
        assert!(login.lines().join("\n").contains("ABCD-1234"));
        let mut stale = pending();
        stale.operation = "z".repeat(43);
        stale.state = LoginState::Complete;
        login.apply(stale);
        assert_eq!(login.done, Some("Invalid daemon login response."));
        assert!(!login.lines().join("\n").contains("ABCD-1234"));
    }

    #[test]
    fn only_displays_the_fixed_verification_url_and_valid_code() {
        let mut login = flow();
        let mut bad = pending();
        bad.verification_url = Some("https://auth.openai.com/codex/device?extra=yes".into());
        bad.user_code = Some("\x1b[2J".into());
        login.apply(bad);
        assert_eq!(
            login.done,
            Some("Invalid verification instructions from daemon.")
        );
        assert!(login.code.is_none());
    }
}
