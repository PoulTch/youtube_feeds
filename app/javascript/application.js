// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Функция, которая ищет все полоски на экране и красит их из памяти Оперы
function applyLocalProgressBars() {
  document.querySelectorAll("[data-local-progress]").forEach(bar => {
    const youtubeId = bar.getAttribute("data-local-progress");
    const savedPercent = localStorage.getItem(`${youtubeId}_percent`);
    
    // Если в памяти браузера есть свежий процент, красим линию им!
    if (savedPercent !== null) {
      bar.style.width = `${savedPercent}%`;
    }
  });
}

// Запускаем при первой загрузке страницы
document.addEventListener("DOMContentLoaded", applyLocalProgressBars);

// Запускаем КАЖДЫЙ РАЗ, когда Turbo переключает страницы (кнопка Назад, переход на Главную)
document.addEventListener("turbo:load", applyLocalProgressBars);
