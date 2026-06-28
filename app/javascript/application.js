// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Функция, которая ищет все полоски на экране и красит их из памяти Оперы
function applyLocalProgressBars() {
  document.querySelectorAll("[data-local-progress]").forEach(bar => {
    const youtubeId = bar.getAttribute("data-local-progress");
    const savedPercent = localStorage.getItem(`${youtubeId}_percent`);
    
    if (savedPercent !== null) {
      bar.style.width = `${savedPercent}%`;
      
      // Если видео просмотрено более чем на 90%
      if (parseInt(savedPercent, 10) >= 90) {
        // Ищем именно карточку видео (поднимаемся до родительского flex-элемента самой сетки видео)
        const videoCard = bar.closest("div[style*='width: 210px']") || bar.closest(".video-card") || bar.parentElement.parentElement;
        if (videoCard && videoCard.style.display !== "none") {
          videoCard.style.display = "none"; // Карточка мгновенно исчезает!
        }
      }
    }
  });
}


// Запускаем при первой загрузке страницы
document.addEventListener("DOMContentLoaded", applyLocalProgressBars);

// Запускаем КАЖДЫЙ РАЗ, когда Turbo переключает страницы (кнопка Назад, переход на Главную)
document.addEventListener("turbo:load", applyLocalProgressBars);
