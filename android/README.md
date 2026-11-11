# VeilGram для Android

Первая сборка поддерживает устройства с Android 6.0 и новее и процессором ARM64. Устанавливается рядом с официальным Telegram под идентификатором `org.veilgram.messenger.web`.

**Настройки → Удалённые сообщения** показывает текст и подписи входящих сообщений, которые были доступны приложению до удаления. Записи остаются в базе текущего аккаунта на телефоне. Архив ограничен 1 000 записями. Секретные чаты, защищённые сообщения и сообщения с таймером исключены.

GitHub Actions собирает подписанный `VeilGram-arm64.apk`. После завершения скачай артефакт **VeilGram-Android**, распакуй архив и открой APK на телефоне.

Сборка использует `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `VEILGRAM_ANDROID_KEYSTORE` (PKCS#12 в Base64, псевдоним `veilgram`) и `VEILGRAM_ANDROID_KEY_PASSWORD`. Для настройки Firebase Cloud Messaging добавь `VEILGRAM_ANDROID_GOOGLE_SERVICES` с конфигурацией приложения `org.veilgram.messenger.web`. Исходники Telegram закреплены в сценарии GitHub Actions.
