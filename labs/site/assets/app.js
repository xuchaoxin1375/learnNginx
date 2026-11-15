document.addEventListener("DOMContentLoaded", function () {
  var target = document.querySelector("[data-current-path]");
  if (target) {
    target.textContent = window.location.pathname;
  }
});
