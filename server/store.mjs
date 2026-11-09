import { createHash, randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const minute = 60_000;
const codeLifetime = 5 * minute;
const sessionLifetime = 180 * 24 * 60 * minute;

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
  const pruneCodes = db.prepare('DELETE FROM codes WHERE expires <= ?');
  const pruneSessions = db.prepare('DELETE FROM sessions WHERE expires <= ?');

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
    close() {
      db.close();
    }
  };
}
