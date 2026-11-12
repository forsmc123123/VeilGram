import { join } from 'node:path';
import qr from 'qrcode-terminal';
import { telegramClient } from './telegram-client.mjs';

export function createVerifier(registration, expected, dataDirectory) {
  const client = telegramClient(join(dataDirectory, 'registration-telegram'), 'registration-telegram', 'VeilGram Registration', false);
  let state;
  let pairedPeer;
  let qrRequested = false;
  let status = 'Starting the VeilGram registration account.';
  let authorization = Promise.resolve();
  client.on('error', () => console.error('VeilGram registration client reported an error.'));
  client.on('update', (update) => {
    if (update._ === 'updateNewMessage') {
      registration.verify(update.message);
    } else if (update._ === 'updateUser' && String(update.user.id) === pairedPeer && state?._ === 'authorizationStateReady') {
      updateDestination(update.user);
    } else if (update._ === 'updateAuthorizationState') {
      state = update.authorization_state;
      const next = state;
      if (next._ !== 'authorizationStateReady') {
        pairedPeer = undefined;
        registration.setReady(undefined);
      }
      authorization = authorization.then(() => handle(next)).catch(() => {
        status = 'Could not authorize the VeilGram registration account.';
        console.error(status);
      });
    }
  });

  function updateDestination(user) {
    const usernames = user.usernames?.active_usernames ?? [];
    const username = expected.username
      ? usernames.find((name) => name.toLowerCase() === expected.username)
      : usernames[0];
    if (user.type?._ !== 'userTypeRegular' || !/^[a-zA-Z0-9_]{5,32}$/.test(username ?? '')) {
      registration.setReady(undefined);
      status = 'Use the configured regular Telegram account and give it a public username.';
      return;
    }
    registration.setReady(username, String(user.id));
    status = `VeilGram registration account @${username} is ready.`;
  }

  async function handle(next) {
    if (next !== state) return;
    switch (next._) {
      case 'authorizationStateWaitPhoneNumber':
        status = 'Run registration login to pair the dedicated Telegram account.';
        break;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        status = 'Scan the pairing QR in Telegram under Settings → Devices.';
        if (qrRequested) {
          qrRequested = false;
          qr.generate(next.link, { small: true }, (image) => console.log(image));
        }
        break;
      case 'authorizationStateWaitPassword': {
        const password = process.env.VEILGRAM_REGISTRATION_PASSWORD;
        status = 'Pairing requires the service account’s Telegram two-step verification password.';
        if (password) await client.invoke({ _: 'checkAuthenticationPassword', password });
        break;
      }
      case 'authorizationStateReady': {
        const user = await client.invoke({ _: 'getMe' });
        if (next !== state) return;
        const peer = String(user.id);
        const names = user.usernames?.active_usernames ?? [];
        if (user.type?._ !== 'userTypeRegular' || (expected.peer && peer !== expected.peer) ||
            (expected.username && !names.some((name) => name.toLowerCase() === expected.username))) {
          status = 'Paired account does not match the configured VeilGram registration account.';
          console.error(status);
          await client.invoke({ _: 'logOut' });
          break;
        }
        pairedPeer = peer;
        updateDestination(user);
        console.log(status);
        break;
      }
      default:
        status = 'VeilGram registration account is offline.';
    }
  }

  return {
    status: () => status,
    async login() {
      if (state?._ === 'authorizationStateWaitOtherDeviceConfirmation') {
        qr.generate(state.link, { small: true }, (image) => console.log(image));
      } else if (state?._ === 'authorizationStateWaitPhoneNumber') {
        qrRequested = true;
        await client.invoke({ _: 'requestQrCodeAuthentication', other_user_ids: [] });
      } else {
        console.log(status);
      }
    }
  };
}
