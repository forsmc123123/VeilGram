package org.telegram.messenger;

import android.text.TextUtils;

import org.telegram.SQLite.SQLiteCursor;
import org.telegram.SQLite.SQLiteDatabase;
import org.telegram.SQLite.SQLitePreparedStatement;
import org.telegram.tgnet.NativeByteBuffer;
import org.telegram.tgnet.TLRPC;

import java.util.ArrayList;
import java.util.List;

public final class VeilGramArchive {
    private static final int LIMIT = 1000;

    private VeilGramArchive() {}

    public interface Listener {
        void loaded(List<Record> records, boolean failed);
    }

    public static final class Record {
        public final String chat;
        public final int date;
        public final String text;

        Record(String chat, int date, String text) {
            this.chat = chat;
            this.date = date;
            this.text = text;
        }
    }

    static void capture(MessagesStorage storage, long selfId, long dialogId, List<Integer> ids) {
        if (ids.isEmpty() || DialogObject.isEncryptedDialog(dialogId)) {
            return;
        }
        SQLiteCursor cursor = null;
        SQLitePreparedStatement insert = null;
        try {
            SQLiteDatabase db = storage.getDatabase();
            createTable(db);
            String scope = dialogId == 0 ? "m.is_channel = 0" : "m.uid = " + dialogId;
            cursor = db.queryFinalized("SELECT m.uid, m.mid, m.data FROM messages_v2 m "
                    + "LEFT JOIN dialogs d ON m.uid = d.did WHERE m.out = 0 AND m.ttl = 0 "
                    + "AND COALESCE(d.ttl_period, 0) = 0 AND " + scope
                    + " AND m.mid IN (" + TextUtils.join(",", ids) + ")");
            insert = db.executeFast("INSERT OR IGNORE INTO veilgram_archive (uid, mid, chat, date, body) VALUES (?, ?, ?, ?, ?)");
            while (cursor.next()) {
                long peer = cursor.longValue(0);
                if (peer == selfId || DialogObject.isEncryptedDialog(peer)) {
                    continue;
                }
                NativeByteBuffer data = cursor.byteBufferValue(2);
                if (data == null) {
                    continue;
                }
                TLRPC.Message message;
                try {
                    message = TLRPC.Message.TLdeserialize(data, data.readInt32(false), false);
                } finally {
                    data.reuse();
                }
                if (!(message instanceof TLRPC.TL_message) || message.out || message.post
                        || message.noforwards || message.ttl_period != 0 || message.expire_date != 0
                        || MessageObject.isEphemeral(message) || TextUtils.isEmpty(message.message)
                        || (message.media != null && message.media.ttl_seconds != 0)) {
                    continue;
                }
                String title;
                if (peer < 0) {
                    TLRPC.Chat chat = storage.getChat(-peer);
                    if (chat == null || chat.noforwards || ChatObject.isChannelAndNotMegaGroup(chat)) {
                        continue;
                    }
                    title = chat.title;
                } else {
                    TLRPC.User user = storage.getUser(peer);
                    title = user == null ? null : UserObject.getUserName(user);
                }
                insert.requery();
                insert.bindLong(1, peer);
                insert.bindInteger(2, cursor.intValue(1));
                insert.bindString(3, TextUtils.isEmpty(title) ? "Чат" : title);
                insert.bindInteger(4, message.date);
                insert.bindString(5, message.message);
                insert.step();
            }
            cursor.dispose();
            cursor = null;
            db.executeFast("DELETE FROM veilgram_archive WHERE rowid IN (SELECT rowid FROM veilgram_archive "
                    + "ORDER BY rowid DESC LIMIT -1 OFFSET " + LIMIT + ")").stepThis().dispose();
        } catch (Exception e) {
            FileLog.e(e);
        } finally {
            if (cursor != null) cursor.dispose();
            if (insert != null) insert.dispose();
        }
    }

    public static void load(int account, Listener listener) {
        MessagesStorage storage = MessagesStorage.getInstance(account);
        storage.getStorageQueue().postRunnable(() -> {
            List<Record> records = new ArrayList<>();
            SQLiteCursor cursor = null;
            boolean failed = false;
            try {
                SQLiteDatabase db = storage.getDatabase();
                createTable(db);
                cursor = db.queryFinalized("SELECT chat, date, body FROM veilgram_archive ORDER BY date DESC, rowid DESC");
                while (cursor.next()) {
                    records.add(new Record(cursor.stringValue(0), cursor.intValue(1), cursor.stringValue(2)));
                }
            } catch (Exception e) {
                FileLog.e(e);
                failed = true;
            } finally {
                if (cursor != null) cursor.dispose();
            }
            boolean loadFailed = failed;
            AndroidUtilities.runOnUIThread(() -> listener.loaded(records, loadFailed));
        });
    }

    private static void createTable(SQLiteDatabase db) throws Exception {
        db.executeFast("CREATE TABLE IF NOT EXISTS veilgram_archive (uid INTEGER, mid INTEGER, "
                + "chat TEXT NOT NULL, date INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY (uid, mid))")
                .stepThis().dispose();
    }
}
