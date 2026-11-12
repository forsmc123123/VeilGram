import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const minute = 60_000;
const codeLifetime = 5 * minute;
const sessionLifetime = 180 * 24 * 60 * minute;

const digest = (value) => createHash('sha256').update(value).digest('hex');

export function createStore(filename, archiveKey) {
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
    CREATE TABLE IF NOT EXISTS appearances (
      peer TEXT PRIMARY KEY, packet BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS archive_accounts (peer TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS archive_messages (
      peer TEXT NOT NULL, chat TEXT NOT NULL, message TEXT NOT NULL,
      received INTEGER NOT NULL, deleted INTEGER, payload BLOB NOT NULL,
      PRIMARY KEY (peer, chat, message)
    );
    CREATE INDEX IF NOT EXISTS archive_message_order ON archive_messages (peer, deleted, received);
  `);

  const getCode = db.prepare('SELECT * FROM codes WHERE peer = ?');
  const setCode = db.prepare('INSERT OR REPLACE INTO codes VALUES (?, ?, ?, 6)');
  const deleteCode = db.prepare('DELETE FROM codes WHERE peer = ? AND digest = ? AND expires > ? AND attempts > 0');
  const useAttempt = db.prepare('UPDATE codes SET attempts = attempts - 1 WHERE peer = ?');
  const addSession = db.prepare('INSERT INTO sessions VALUES (?, ?, ?)');
  const getSession = db.prepare('SELECT peer FROM sessions WHERE digest = ? AND expires > ?');
  const getProfile = db.prepare('SELECT banner, gifts FROM profiles WHERE peer = ?');
  const putProfile = db.prepare('INSERT OR REPLACE INTO profiles VALUES (?, ?, ?)');
  const deleteProfile = db.prepare('DELETE FROM profiles WHERE peer = ?');
  const getAppearance = db.prepare('SELECT packet FROM appearances WHERE peer = ?');
  const getAppearancePrefix = db.prepare('SELECT substr(packet, 1, 2052) AS prefix FROM appearances WHERE peer = ?');
  const getAppearanceMedia = db.prepare('SELECT substr(packet, ?) AS media FROM appearances WHERE peer = ?');
  const putAppearance = db.prepare('INSERT OR REPLACE INTO appearances VALUES (?, ?)');
  const addAppearance = db.prepare('INSERT OR IGNORE INTO appearances VALUES (?, ?)');
  const registrationHeader = Buffer.from(JSON.stringify({ version: 2, profile: { member: true } }));
  const registrationPacket = Buffer.alloc(4 + registrationHeader.length);
  registrationPacket.writeUInt32BE(registrationHeader.length);
  registrationHeader.copy(registrationPacket, 4);
  const archiveAccounts = db.prepare('SELECT peer FROM archive_accounts');
  const enableArchive = db.prepare('INSERT OR IGNORE INTO archive_accounts VALUES (?)');
  const disableArchive = db.prepare('DELETE FROM archive_accounts WHERE peer = ?');
  const stageMessage = db.prepare(`
    INSERT INTO archive_messages VALUES (?, ?, ?, ?, NULL, ?)
    ON CONFLICT (peer, chat, message) DO UPDATE SET payload = excluded.payload WHERE deleted IS NULL
  `);
  const stagedMessage = db.prepare('SELECT payload FROM archive_messages WHERE peer = ? AND chat = ? AND message = ? AND deleted IS NULL');
  const markDeleted = db.prepare('UPDATE archive_messages SET deleted = ? WHERE peer = ? AND chat = ? AND message = ? AND deleted IS NULL');
  const deleteStagedChat = db.prepare('DELETE FROM archive_messages WHERE peer = ? AND chat = ? AND deleted IS NULL');
  const deleteStaged = db.prepare('DELETE FROM archive_messages WHERE peer = ? AND deleted IS NULL');
  const pruneExpired = db.prepare('DELETE FROM archive_messages WHERE deleted IS NULL AND received < ?');
  const pruneStaged = db.prepare(`
    DELETE FROM archive_messages WHERE rowid IN (
      SELECT rowid FROM archive_messages WHERE peer = ? AND deleted IS NULL ORDER BY received DESC, rowid DESC LIMIT -1 OFFSET 2000
    )
  `);
  const pruneDeleted = db.prepare(`
    DELETE FROM archive_messages WHERE rowid IN (
      SELECT rowid FROM archive_messages WHERE peer = ? AND deleted IS NOT NULL ORDER BY deleted DESC, rowid DESC LIMIT -1 OFFSET 1000
    )
  `);
  const readDeleted = db.prepare('SELECT chat, message, payload FROM archive_messages WHERE peer = ? AND deleted IS NOT NULL ORDER BY deleted DESC, rowid DESC');
  const pruneCodes = db.prepare('DELETE FROM codes WHERE expires <= ?');
  const pruneSessions = db.prepare('DELETE FROM sessions WHERE expires <= ?');

  function issueSession(peer, now) {
    const token = randomBytes(32).toString('base64url');
    pruneSessions.run(now);
    addSession.run(digest(token), peer, now + sessionLifetime);
    return token;
  }

  function seal(peer, chat, message, value) {
    const key = createHmac('sha256', archiveKey).update(`archive:${peer}`).digest();
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(Buffer.from(`${chat}:${message}`));
    const content = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    return Buffer.concat([nonce, cipher.getAuthTag(), content]);
  }

  function open(peer, chat, message, payload) {
    const key = createHmac('sha256', archiveKey).update(`archive:${peer}`).digest();
    const decipher = createDecipheriv('aes-256-gcm', key, payload.subarray(0, 12));
    decipher.setAAD(Buffer.from(`${chat}:${message}`));
    decipher.setAuthTag(payload.subarray(12, 28));
    return JSON.parse(Buffer.concat([decipher.update(payload.subarray(28)), decipher.final()]));
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

      db.exec('BEGIN IMMEDIATE');
      try {
        if (deleteCode.run(peer, current.digest, now).changes === 0) {
          db.exec('ROLLBACK');
          return;
        }
        const token = issueSession(peer, now);
        db.exec('COMMIT');
        return token;
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
    },
    registerPeer(peer, now) {
      db.exec('BEGIN IMMEDIATE');
      try {
        const token = issueSession(peer, now);
        const created = addAppearance.run(peer, registrationPacket).changes > 0;
        db.exec('COMMIT');
        return { token, created };
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
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
    appearance(peer) {
      return getAppearance.get(peer)?.packet;
    },
    appearancePrefix(peer) {
      return getAppearancePrefix.get(peer)?.prefix;
    },
    appearanceMedia(peer, offset) {
      return getAppearanceMedia.get(offset + 1, peer)?.media;
    },
    saveAppearance(peer, packet) {
      putAppearance.run(peer, packet);
    },
    archiveAccounts() {
      return archiveAccounts.all().map(({ peer }) => peer);
    },
    setArchiveEnabled(peer, enabled) {
      if (enabled) {
        enableArchive.run(peer);
      } else {
        disableArchive.run(peer);
        deleteStaged.run(peer);
      }
    },
    expireStaged(now = Date.now()) {
      pruneExpired.run(now - 7 * 24 * 60 * minute);
    },
    stageMessage(peer, chat, message, value, now = Date.now()) {
      stageMessage.run(peer, chat, message, now, seal(peer, chat, message, value));
      pruneStaged.run(peer);
    },
    editStagedMessage(peer, chat, message, text) {
      const row = stagedMessage.get(peer, chat, message);
      if (!row) return;
      const previous = open(peer, chat, message, row.payload);
      stageMessage.run(peer, chat, message, Date.now(), seal(peer, chat, message, { ...previous, text }));
    },
    discardStagedChat(peer, chat) {
      deleteStagedChat.run(peer, chat);
    },
    archiveDeletions(peer, chat, messages, now = Date.now()) {
      db.exec('BEGIN IMMEDIATE');
      try {
        this.expireStaged(now);
        for (const message of messages) markDeleted.run(now, peer, chat, message);
        pruneDeleted.run(peer);
        db.exec('COMMIT');
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
    },
    deletedMessages(peer) {
      if (!archiveKey) return [];
      return readDeleted.all(peer).map(({ chat, message, payload }) => open(peer, chat, message, payload));
    },
    close() {
      db.close();
    }
  };
}
