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
      
      // Намертво красим полоску прогресса на основе localStorage браузера
      bar.style.width = `${Math.min(percentInt, 100)}%`;
      
      // УМНАЯ КАРУСЕЛЬ: Если видео из карусели истории просмотрено более чем на 90%
      if (percentInt >= 90) {
        // Ищем карточку строго внутри карусели по нашему новому классу!
        const historyCard = bar.closest(".history-card-item");
        if (historyCard && historyCard.style.display !== "none") {
          historyCard.style.display = "none"; // Карточка мгновенно и красиво исчезает ТОЛЬКО из истории!
          console.log(`[MyChannels JS] Ролик ${youtubeId} скрыт из карусели истории (прогресс ${percentInt}%)`);
        }
      }
    }
  });
}

// Запускаем при первой загрузке страницы
document.addEventListener("DOMContentLoaded", applyLocalProgressBars);

// Запускаем КАЖДЫЙ РАЗ, когда Turbo переключает страницы (кнопка Назад, переход на Главную)
document.addEventListener("turbo:load", applyLocalProgressBars);
