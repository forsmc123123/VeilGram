import { randomBytes } from 'node:crypto';

const lifetime = 120_000;
const peerPattern = /^[1-9][0-9]{0,15}$/;
const pollPattern = /^[A-Za-z0-9_-]{43}$/;
const messagePattern = /^VEILGRAM-REGISTER ([a-f0-9]{32})$/;

export function createRegistration(store, recipient, clock = Date.now) {
  const byPoll = new Map();
  const byProof = new Map();
  let destination;

  function remove(challenge) {
    byPoll.delete(challenge.poll);
    byProof.delete(challenge.proof);
  }

  return {
    ready: () => Boolean(destination),
    setReady(username) {
      destination = username ? { username, recipient } : undefined;
    },
    start(peer, address) {
      const now = clock();
      if (!destination || typeof peer !== 'string' || !peerPattern.test(peer) || peer === recipient) return;
      let requestsFromAddress = 0;
      for (const challenge of byPoll.values()) {
        if (challenge.expires <= now) remove(challenge);
        else if (challenge.address === address) requestsFromAddress++;
      }
      if (byPoll.size >= 512 || requestsFromAddress >= 12) return;
      const proof = randomBytes(16).toString('hex');
      const poll = randomBytes(32).toString('base64url');
      const challenge = { peer, address, proof, poll, expires: now + lifetime, verified: false };
      byPoll.set(poll, challenge);
      byProof.set(proof, challenge);
      return { ...destination, proof, poll };
    },
    verify(message) {
      if (!destination || message?.is_outgoing || message?.forward_info || message?.via_bot_user_id ||
          message?.sender_id?._ !== 'messageSenderUser' || message?.content?._ !== 'messageText') return;
      const peer = String(message.sender_id.user_id);
      if (peer !== String(message.chat_id)) return;
      const match = messagePattern.exec(message.content.text?.text ?? '');
      const challenge = match && byProof.get(match[1]);
      if (!challenge || challenge.peer !== peer || challenge.expires <= clock()) return;
      challenge.verified = true;
      byProof.delete(challenge.proof);
    },
    complete(poll) {
      if (typeof poll !== 'string' || !pollPattern.test(poll)) return;
      const challenge = byPoll.get(poll);
      if (!challenge) return;
      const now = clock();
      if (challenge.expires <= now) {
        remove(challenge);
        return;
      }
      if (!challenge.verified) return { pending: true };
      const session = store.registerPeer(challenge.peer, now);
      remove(challenge);
      return session;
    }
  };
}
