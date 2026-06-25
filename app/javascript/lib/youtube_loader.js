let apiLoadingPromise = null;

export function loadYouTubeAPI() {
  if (window.YT && window.YT.Player) {
    return Promise.resolve(window.YT);
  }

  if (apiLoadingPromise) {
    return apiLoadingPromise;
  }

  apiLoadingPromise = new Promise((resolve) => {
    // Создаем глобальный колбэк, который вызовет YouTube
    window.onYouTubeIframeAPIReady = () => {
      resolve(window.YT);
    };

    // Загружаем сам скрипт
    const tag = document.createElement('script');
    tag.src = "https://youtube.com";
    const firstScriptTag = document.getElementsByTagName('script')[0];
    if (firstScriptTag) {
      firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
    } else {
      document.head.appendChild(tag);
    }
  });

  return apiLoadingPromise;
}
