import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { videoId: Number }

  connect() {
    this.interval = setInterval(() => {
      this.saveProgress()
    }, 5000) // Сохраняем каждые 5 секунд
  }

  disconnect() {
    clearInterval(this.interval)
    this.saveProgress() // Сохраняем финальный прогресс при уходе со страницы
  }

  saveProgress() {
    // Так как YouTube блокирует прямой доступ к iframe, мы пока симулируем получение времени,
    // либо в будущем подключим официальный YouTube Player API Скрипт.
    // Сейчас сделаем базовый рабочий запрос на бэкенд для проверки связи.
    
    const url = `/videos/${this.videoIdValue}/save_progress`
    const token = document.querySelector('meta[name="csrf-token"]').getAttribute('content')

    // Для теста будем отправлять, что мы посмотрели еще 5 секунд
    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify({ current_time: 120, total_time: 600 }) // 2 минуты из 10 (для теста)
    })
  }
}
