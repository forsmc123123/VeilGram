import { createHash, randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const minute = 60_000;
const codeLifetime = 5 * minute;
const sessionLifetime = 180 * 24 * 60 * minute;
const initialBalance = 1000;

const digest = (value) => createHash('sha256').update(value).digest('hex');

export function createStore(filename) {
  const db = new DatabaseSync(filename);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS codes (
      peer TEXT PRIMARY KEY, digest TEXT NOT NULL,
      expires INTEGER NOT NULL, attempts INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      digest TEXT PRIMARY KEY, peer TEXT NOT NULL, expires INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS profiles (
      peer TEXT PRIMARY KEY, banner TEXT, gifts TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS members (
      peer TEXT PRIMARY KEY, balance INTEGER NOT NULL, style TEXT
    );
    CREATE TABLE IF NOT EXISTS avatar_media (
      peer TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL, data BLOB NOT NULL,
      PRIMARY KEY (peer, id)
    );
    CREATE TABLE IF NOT EXISTS visual_gifts (
      id INTEGER PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL,
      nonce TEXT NOT NULL, item TEXT NOT NULL, UNIQUE (sender, nonce)
    );
    CREATE INDEX IF NOT EXISTS visual_gifts_recipient ON visual_gifts(recipient, id DESC);
  `);
  db.prepare('INSERT OR IGNORE INTO members (peer, balance) SELECT DISTINCT peer, ? FROM sessions WHERE expires > ?').run(initialBalance, Date.now());

  const getCode = db.prepare('SELECT * FROM codes WHERE peer = ?');
  const setCode = db.prepare('INSERT OR REPLACE INTO codes VALUES (?, ?, ?, 6)');
  const deleteCode = db.prepare('DELETE FROM codes WHERE peer = ? AND digest = ? AND expires > ? AND attempts > 0');
  const useAttempt = db.prepare('UPDATE codes SET attempts = attempts - 1 WHERE peer = ?');
  const addSession = db.prepare('INSERT INTO sessions VALUES (?, ?, ?)');
  const getSession = db.prepare('SELECT peer FROM sessions WHERE digest = ? AND expires > ?');
  const getProfile = db.prepare('SELECT banner, gifts FROM profiles WHERE peer = ?');
  const putProfile = db.prepare('INSERT OR REPLACE INTO profiles VALUES (?, ?, ?)');
  const deleteProfile = db.prepare('DELETE FROM profiles WHERE peer = ?');
  const pruneCodes = db.prepare('DELETE FROM codes WHERE expires <= ?');
  const pruneSessions = db.prepare('DELETE FROM sessions WHERE expires <= ?');
  const addMember = db.prepare('INSERT OR IGNORE INTO members (peer, balance) VALUES (?, ?)');
  const getMember = db.prepare('SELECT balance, style FROM members WHERE peer = ?');
  const saveStyle = db.prepare('UPDATE members SET style = ? WHERE peer = ?');
  const debit = db.prepare('UPDATE members SET balance = balance - ? WHERE peer = ? AND balance >= ?');
  const putMedia = db.prepare('INSERT OR IGNORE INTO avatar_media VALUES (?, ?, ?, ?)');
  const getMedia = db.prepare('SELECT kind, data FROM avatar_media WHERE peer = ? AND id = ?');
  const hasMedia = db.prepare('SELECT kind FROM avatar_media WHERE peer = ? AND id = ?');
  const pruneMedia = db.prepare('DELETE FROM avatar_media WHERE peer = ? AND id != ? AND id != ?');
  const giftByNonce = db.prepare('SELECT recipient, item FROM visual_gifts WHERE sender = ? AND nonce = ?');
  const addGift = db.prepare('INSERT INTO visual_gifts (sender, recipient, nonce, item) VALUES (?, ?, ?, ?)');
  const receivedGifts = db.prepare('SELECT item FROM visual_gifts WHERE recipient = ? ORDER BY id DESC LIMIT 6');

  function transact(action) {
    db.exec('BEGIN IMMEDIATE');
    try {
      const result = action();
      db.exec('COMMIT');
      return result;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }

  function styleFor(peer, member) {
    return member.style ? JSON.parse(member.style) : { banner: getProfile.get(peer)?.banner ?? null };
  }

  return {
    issueCode(peer, now = Date.now()) {
      pruneCodes.run(now);
      const previous = getCode.get(peer);
      if (previous && previous.expires > now + codeLifetime - 30_000) return;

      const code = randomBytes(4).toString('hex').toUpperCase();
      setCode.run(peer, digest(code), now + codeLifetime);
      return code;
    },
    redeemCode(peer, code, now = Date.now()) {
      const current = getCode.get(peer);
      if (!current || current.expires <= now || current.attempts <= 0) return;
      if (current.digest !== digest(code)) {
        useAttempt.run(peer);
        return;
      }

      const token = randomBytes(32).toString('base64url');
      db.exec('BEGIN IMMEDIATE');
      try {
        if (deleteCode.run(peer, current.digest, now).changes === 0) {
          db.exec('ROLLBACK');
          return;
        }
        pruneSessions.run(now);
        addSession.run(digest(token), peer, now + sessionLifetime);
        addMember.run(peer, initialBalance);
        db.exec('COMMIT');
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
      return token;
    },
    authenticatedPeer(token, now = Date.now()) {
      return getSession.get(digest(token), now)?.peer;
    },
    getProfile(peer) {
      const row = getProfile.get(peer);
      return row ? { banner: row.banner, gifts: JSON.parse(row.gifts) } : { banner: null, gifts: [] };
    },
    saveProfile(peer, profile) {
      if (profile.banner === null && profile.gifts.length === 0) {
        deleteProfile.run(peer);
      } else {
        putProfile.run(peer, profile.banner, JSON.stringify(profile.gifts));
      }
    },
    getSharedProfile(peer, viewer) {
      const member = getMember.get(peer);
      if (!member) return { member: false };
      return {
        ...styleFor(peer, member),
        member: true,
        received: receivedGifts.all(peer).map(({ item }) => item),
        ...(peer === viewer ? { balance: member.balance } : {})
      };
    },
    saveStyle(peer, style) {
      return transact(() => {
        if (style.media && hasMedia.get(peer, style.media.id)?.kind !== style.media.kind) return false;
        saveStyle.run(JSON.stringify(style), peer);
        pruneMedia.run(peer, style.media?.id ?? '', '');
        return true;
      });
    },
    uploadMedia(peer, kind, data) {
      const id = createHash('sha256').update(kind).update(data).digest('hex');
      return transact(() => {
        const current = styleFor(peer, getMember.get(peer)).media?.id ?? '';
        putMedia.run(peer, id, kind, data);
        pruneMedia.run(peer, id, current);
        return { id, kind };
      });
    },
    getMedia(peer, id, viewer) {
      const member = getMember.get(peer);
      if (!member || (peer !== viewer && styleFor(peer, member).media?.id !== id)) return;
      return getMedia.get(peer, id);
    },
    sendGift(sender, recipient, nonce, item, cost) {
      return transact(() => {
        const previous = giftByNonce.get(sender, nonce);
        if (previous) {
          return previous.recipient === recipient && previous.item === item
            ? { balance: getMember.get(sender).balance }
            : { error: 'nonce_conflict' };
        }
        if (!getMember.get(recipient)) return { error: 'recipient_not_linked' };
        if (!debit.run(cost, sender, cost).changes) return { error: 'insufficient_stars' };
        addGift.run(sender, recipient, nonce, item);
        return { balance: getMember.get(sender).balance };
      });
    },
    close() {
      db.close();
    }
  };
}
