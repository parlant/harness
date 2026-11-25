const ballroom = document.querySelector('.ballroom');
if (ballroom && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) {
      ballroom.classList.add('ballroom-entered');
      observer.disconnect();
    }
  }, { threshold: 0.35 });
  observer.observe(ballroom);
}
