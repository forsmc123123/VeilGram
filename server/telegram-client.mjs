import { createHmac } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import tdl from 'tdl';
import { getTdjson } from 'prebuilt-tdlib';

tdl.configure({ tdjson: getTdjson(), verbosityLevel: 0 });

export function telegramClient(directory, keyContext, device, keepChatInfo) {
  const apiId = Number(process.env.TELEGRAM_API_ID);
  const apiHash = process.env.TELEGRAM_API_HASH;
  const archiveKey = process.env.ARCHIVE_KEY;
  if (!Number.isInteger(apiId) || apiId < 1 || apiId > 2147483647 ||
      !/^[a-f0-9]{32}$/i.test(apiHash ?? '') || !/^[a-f0-9]{64}$/i.test(archiveKey ?? '')) {
    throw new Error('Invalid Telegram client configuration.');
  }
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  return tdl.createClient({
    apiId,
    apiHash,
    databaseDirectory: directory,
    filesDirectory: join(directory, 'files'),
    databaseEncryptionKey: createHmac('sha256', Buffer.from(archiveKey, 'hex')).update(keyContext).digest('hex'),
    tdlibParameters: {
      use_message_database: false,
      use_chat_info_database: keepChatInfo,
      use_secret_chats: false,
      system_language_code: 'ru',
      device_model: device,
      application_version: '1.0'
    }
  });
}
