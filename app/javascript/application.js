// Configure your import map in config/importmap.rb. Read more: https://github.com
import "@hotwired/turbo-rails"
import "controllers"

function applyLocalProgressBars() {
  console.log("--> [MyChannels JS] Запуск сканирования локального прогресса...");
  document.querySelectorAll("[data-local-progress]").forEach(bar => {
    const youtubeId = bar.getAttribute("data-local-progress");
    if (!youtubeId) return;

    const savedPercent = localStorage.getItem(`${youtubeId}_percent`);
    if (savedPercent !== null) {
      const percentInt = parseInt(savedPercent, 10);
      bar.style.width = `${Math.min(percentInt, 100)}%`;
    }
  });
}

// Запускаем при первой загрузке страницы
document.addEventListener("DOMContentLoaded", applyLocalProgressBars);

// Запускаем КАЖДЫЙ РАЗ, когда Turbo переключает страницы (кнопка Назад, переход на Главную)
document.addEventListener("turbo:load", applyLocalProgressBars);