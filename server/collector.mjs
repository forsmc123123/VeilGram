import { join } from 'node:path';
import { telegramClient } from './telegram-client.mjs';

const textContent = new Set([
  'messageText', 'messagePhoto', 'messageVideo', 'messageDocument', 'messageAnimation', 'messageAudio', 'messageVoiceNote'
]);

function messageText(content) {
  if (!textContent.has(content?._)) return;
  return String(content.text?.text ?? content.caption?.text ?? 'Вложение').slice(0, 4096);
}

function isOrdinaryChat(chat, peer) {
  const type = chat.type;
  return !chat.has_protected_content && chat.message_auto_delete_time === 0 &&
    ((type._ === 'chatTypePrivate' && String(type.user_id) !== peer && type.user_id !== 777000) ||
      type._ === 'chatTypeBasicGroup' || (type._ === 'chatTypeSupergroup' && !type.is_channel));
}

export function createCollector(store, dataDirectory) {
  const clients = new Map();
  const cleanup = setInterval(() => store.expireStaged(), 60 * 60 * 1000);
  cleanup.unref();
  store.expireStaged();

  async function stop(peer, entry, logout) {
    if (entry.stopping) return;
    entry.stopping = true;
    entry.active = false;
    clearTimeout(entry.timeout);
    store.setArchiveEnabled(peer, false);
    try {
      if (logout) await entry.client.invoke({ _: 'logOut' });
      await entry.client.close();
    } catch {
      try { await entry.client.close(); } catch { /* TDLib may already be closed. */ }
    } finally {
      if (clients.get(peer) === entry) clients.delete(peer);
    }
  }

  async function handle(peer, entry, update) {
    if (entry.stopping) return;
    if (update._ === 'updateAuthorizationState') {
      const state = update.authorization_state;
      switch (state._) {
        case 'authorizationStateWaitPhoneNumber':
          entry.state = 'pairing';
          await entry.client.invoke({ _: 'requestQrCodeAuthentication', other_user_ids: [] });
          break;
        case 'authorizationStateWaitOtherDeviceConfirmation':
          entry.state = 'qr';
          entry.qr = state.link;
          break;
        case 'authorizationStateWaitPassword':
          entry.state = 'password';
          entry.qr = undefined;
          break;
        case 'authorizationStateReady': {
          entry.authorized = true;
          const me = await entry.client.invoke({ _: 'getMe' });
          if (entry.stopping) return;
          if (String(me.id) !== peer) {
            await stop(peer, entry, true);
            break;
          }
          clearTimeout(entry.timeout);
          entry.active = true;
          entry.state = 'connected';
          entry.qr = undefined;
          store.setArchiveEnabled(peer, true);
          break;
        }
        case 'authorizationStateClosing':
        case 'authorizationStateClosed':
        case 'authorizationStateLoggingOut':
          if (!entry.stopping) await stop(peer, entry, false);
          break;
        default:
          break;
      }
      return;
    }
    if (!entry.active) return;
    const chatId = String(update.chat_id);
    if (update._ === 'updateDeleteMessages' && update.is_permanent && !update.from_cache) {
      store.archiveDeletions(peer, chatId, update.message_ids.map(String));
    } else if ((update._ === 'updateChatHasProtectedContent' && update.has_protected_content) ||
               (update._ === 'updateChatMessageAutoDeleteTime' && update.message_auto_delete_time > 0)) {
      store.discardStagedChat(peer, chatId);
    } else if (update._ === 'updateMessageContent') {
      const text = messageText(update.new_content);
      if (text) store.editStagedMessage(peer, chatId, String(update.message_id), text);
    } else if (update._ === 'updateNewMessage') {
      const message = update.message;
      const text = messageText(message.content);
      if (!text || message.is_outgoing || message.self_destruct_type ||
          message.self_destruct_in > 0 || message.auto_delete_in > 0) return;
      const chat = await entry.client.invoke({ _: 'getChat', chat_id: message.chat_id });
      if (!isOrdinaryChat(chat, peer)) return;
      const properties = typeof message.can_be_saved === 'boolean' ? message : await entry.client.invoke({
        _: 'getMessageProperties', chat_id: message.chat_id, message_id: message.id
      });
      if (!entry.active || !properties.can_be_saved) return;
      const messageId = String(message.id);
      const chatId = String(message.chat_id);
      store.stageMessage(peer, chatId, messageId, { chatId, messageId, chat: chat.title, timestamp: message.date, text });
    }
  }

  function connect(peer) {
    if (clients.has(peer)) return true;
    if (clients.size >= 15 || !/^[1-9][0-9]{0,15}$/.test(peer) || peer === process.env.VEILGRAM_REGISTRATION_PEER) return false;
    const directory = join(dataDirectory, 'telegram', peer);
    const client = telegramClient(directory, `telegram:${peer}`, 'VeilGram Archive', true);
    const entry = { client, state: 'pairing', queue: Promise.resolve(), active: false, authorized: false, stopping: false };
    clients.set(peer, entry);
    entry.timeout = setTimeout(() => void stop(peer, entry, entry.authorized), 5 * 60 * 1000);
    entry.timeout.unref();
    client.on('error', () => console.error('VeilGram archive client reported an error.'));
    client.on('update', (update) => {
      entry.queue = entry.queue.then(() => handle(peer, entry, update)).catch(() => {
        if (!entry.active) void stop(peer, entry, entry.authorized);
      });
    });
    return true;
  }

  for (const peer of store.archiveAccounts()) connect(peer);
  return {
    connect,
    status(peer) {
      const entry = clients.get(peer);
      if (!entry || entry.stopping) return { state: 'disconnected' };
      return { state: entry.state, qr: entry.qr };
    },
    async checkPassword(peer, password) {
      const entry = clients.get(peer);
      if (entry?.state !== 'password' || entry.stopping || entry.checkingPassword) return false;
      entry.checkingPassword = true;
      try {
        await entry.client.invoke({ _: 'checkAuthenticationPassword', password });
        return true;
      } catch {
        return false;
      } finally {
        entry.checkingPassword = false;
      }
    },
    async disconnect(peer) {
      const entry = clients.get(peer);
      if (entry) await stop(peer, entry, entry.authorized);
    }
  };
}
