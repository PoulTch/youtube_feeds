import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { videoId: Number }

  connect() {
    this.iframe = document.getElementById("youtube-player")
    if (!this.iframe) return

    // Загружаем скрипт YouTube API напрямую, если его еще нет на странице
    if (!window.YT) {
      const tag = document.createElement('script')
      tag.src = "https://youtube.com"
      document.head.appendChild(tag)
    }

    // Запускаем постоянную проверку готовности плеера каждые 500 мс
    this.checkInterval = setInterval(() => {
      if (window.YT && window.YT.Player) {
        clearInterval(this.checkInterval)
        this.initializePlayer()
      }
    }, 500)
  }

  disconnect() {
    this.stopTracking()
    this.saveProgress()
  }

  initializePlayer() {
    // Подключаемся к iframe напрямую по ID
    this.player = new window.YT.Player('youtube-player', {
      events: {
        'onReady': () => { 
          console.log("=== Плеер YouTube успешно подключен к Stimulus! ===")
          this.startTracking() 
        },
        'onStateChange': (event) => {
          if (event.data === 1) this.startTracking() // Видео запущено
          else this.saveProgress() // Пауза, буферизация или конец видео
        }
      }
    })
  }

  startTracking() {
    this.stopTracking()
    // Каждые 3 секунды забираем время и шлем на бэкенд
    this.trackingInterval = setInterval(() => {
      this.saveProgress()
    }, 3000)
  }

  stopTracking() {
    if (this.trackingInterval) clearInterval(this.trackingInterval)
  }

  saveProgress() {
    if (!this.player || typeof this.player.getCurrentTime !== 'function') return

    try {
      const currentTime = Math.round(this.player.getCurrentTime())
      const totalTime = Math.round(this.player.getDuration())

      if (currentTime <= 0 || totalTime <= 0) return

      const url = `/videos/${this.videoIdValue}/save_progress`
      const token = document.querySelector('meta[name="csrf-token"]').getAttribute('content')

      fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token
        },
        body: JSON.stringify({ current_time: currentTime, total_time: totalTime })
      })
    } catch (e) {
      console.log("Ошибка получения времени из плеера:", e)
    }
  }
}
