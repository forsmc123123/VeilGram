import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const source = resolve(process.argv[2]);
const java = 'TMessagesProj/src/main/java/org/telegram';
const applicationId = 'org.veilgram.messenger';
const standaloneId = `${applicationId}.web`;

async function edit(path, replacements) {
    const destination = join(source, path);
    let contents = (await readFile(destination, 'utf8')).replaceAll('\r\n', '\n');
    for (const [before, after] of replacements) {
        if (contents.split(before).length !== 2) {
            throw new Error(`Expected one match in ${path}: ${before}`);
        }
        contents = contents.replace(before, () => after);
    }
    await writeFile(destination, contents);
}

await edit(`${java}/messenger/MessagesController.java`, [[
    '                    ArrayList<Long> dialogIds = getMessagesStorage().markMessagesAsDeleted(key, arrayList, false, true, 0, 0);',
    '                    VeilGramArchive.capture(getMessagesStorage(), getUserConfig().getClientUserId(), key, arrayList);\n'
    + '                    ArrayList<Long> dialogIds = getMessagesStorage().markMessagesAsDeleted(key, arrayList, false, true, 0, 0);',
]]);

await edit(`${java}/ui/ProfileActivity.java`, [
    ['    private int chatRow;', '    private int chatRow;\n    private int veilGramArchiveRow;'],
    ['        chatRow = -1;', '        chatRow = -1;\n        veilGramArchiveRow = -1;'],
    ['                chatRow = rowCount++;', '                chatRow = rowCount++;\n                veilGramArchiveRow = rowCount++;'],
    ['\n            } else if (position == chatRow) {\n', '\n            } else if (position == veilGramArchiveRow) {\n'
        + '                presentFragment(new VeilGramArchiveActivity());\n'
        + '            } else if (position == chatRow) {\n'],
    ['                    } else if (position == filtersRow) {\n                        textCell.setTextAndIcon',
        '                    } else if (position == veilGramArchiveRow) {\n'
        + '                        textCell.setTextAndIcon("Удалённые сообщения", R.drawable.msg_delete, true);\n'
        + '                    } else if (position == filtersRow) {\n                        textCell.setTextAndIcon'],
    ['return position == notificationRow ||', 'return position == veilGramArchiveRow || position == notificationRow ||'],
    ['position == languageRow || position == dataRow || position == chatRow ||',
        'position == veilGramArchiveRow || position == languageRow || position == dataRow || position == chatRow ||'],
    ['            put(++pointer, chatRow, sparseIntArray);',
        '            put(++pointer, chatRow, sparseIntArray);\n            put(++pointer, veilGramArchiveRow, sparseIntArray);'],
]);

await copyFile(new URL('./VeilGramArchive.java', import.meta.url), join(source, java, 'messenger/VeilGramArchive.java'));
await copyFile(new URL('./VeilGramArchiveActivity.java', import.meta.url), join(source, java, 'ui/VeilGramArchiveActivity.java'));

const manifest = 'TMessagesProj/config/release/AndroidManifest_standalone.xml';
await edit(manifest, [['android:label="@string/AppName"', 'android:label="VeilGram"'],
    ['android:icon="@mipmap/ic_launcher_sa"', 'android:icon="@drawable/veilgram_launcher"']]);
const drawables = 'TMessagesProj_AppStandalone/src/main/res/drawable-nodpi';
await mkdir(join(source, drawables), { recursive: true });
await copyFile(new URL('../ios/branding/veilgram-preview.png', import.meta.url), join(source, drawables, 'veilgram_launcher.png'));

await edit('gradle.properties', [['APP_PACKAGE=org.telegram.messenger', `APP_PACKAGE=${applicationId}`]]);
await edit('TMessagesProj_AppStandalone/build.gradle', [[
    'abiFilters "armeabi-v7a", "arm64-v8a", "x86", "x86_64"', 'abiFilters "arm64-v8a"',
]]);

const firebasePath = 'TMessagesProj_AppStandalone/google-services.json';
const firebase = JSON.parse(process.env.VEILGRAM_ANDROID_GOOGLE_SERVICES || await readFile(join(source, firebasePath), 'utf8'));
if (!process.env.VEILGRAM_ANDROID_GOOGLE_SERVICES) {
    for (const client of firebase.client) {
        const android = client.client_info.android_client_info;
        if (android.package_name === 'org.telegram.messenger.web') {
            android.package_name = standaloneId;
        }
    }
}
if (!firebase.client.some(client => client.client_info.android_client_info.package_name === standaloneId)) {
    throw new Error(`Firebase configuration is missing ${standaloneId}`);
}
await writeFile(join(source, firebasePath), JSON.stringify(firebase));

const id = process.env.TELEGRAM_API_ID ?? '';
const hash = process.env.TELEGRAM_API_HASH ?? '';
if (!/^[1-9]\d{0,9}$/.test(id) || Number(id) > 2147483647 || !/^[a-fA-F0-9]{32}$/.test(hash)) {
    throw new Error('Set TELEGRAM_API_ID and TELEGRAM_API_HASH');
}
const buildVars = `${java}/messenger/BuildVars.java`;
const buildVarsPath = join(source, buildVars);
const contents = await readFile(buildVarsPath, 'utf8');
const apiId = contents.match(/public static int APP_ID = \d+;/)?.[0];
const apiHash = contents.match(/public static String APP_HASH = "[a-f0-9]+";/)?.[0];
if (!apiId || !apiHash) {
    throw new Error('Telegram API defaults have changed upstream');
}
await edit(buildVars, [[apiId, `public static int APP_ID = ${id};`],
    [apiHash, `public static String APP_HASH = "${hash}";`],
    ['public static boolean CHECK_UPDATES = true;', 'public static boolean CHECK_UPDATES = false;'],
    ['public static boolean SUPPORTS_PASSKEYS = true;', 'public static boolean SUPPORTS_PASSKEYS = false;'],
    ['public static boolean SUPPORTS_FPNV = true;', 'public static boolean SUPPORTS_FPNV = false;']]);
