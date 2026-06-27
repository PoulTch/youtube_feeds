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

      // НАША НОВАЯ МАГИЯ: если просмотрено больше 90%, находим всю карточку видео и стираем её из HTML!
      if (parseInt(savedPercent, 10) >= 90) {
        // Ищем самый верхний блок карточки (контейнер со стилями, в котором лежит полоска)
        const videoCard = bar.closest("[style*='width: 210px']") || bar.closest("div[style*='flex-direction']");
        if (videoCard) {
          videoCard.style.display = "none"; // Ролик исчезает мгновенно!
        }
      }        
    }
  });
}

// Запускаем при первой загрузке страницы
document.addEventListener("DOMContentLoaded", applyLocalProgressBars);

// Запускаем КАЖДЫЙ РАЗ, когда Turbo переключает страницы (кнопка Назад, переход на Главную)
document.addEventListener("turbo:load", applyLocalProgressBars);
