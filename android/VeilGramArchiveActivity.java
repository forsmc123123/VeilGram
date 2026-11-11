package org.telegram.ui;

import android.content.Context;
import android.text.TextUtils;
import android.text.format.DateUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import org.telegram.messenger.AndroidUtilities;
import org.telegram.messenger.R;
import org.telegram.messenger.VeilGramArchive;
import org.telegram.ui.ActionBar.ActionBar;
import org.telegram.ui.ActionBar.AlertDialog;
import org.telegram.ui.ActionBar.BaseFragment;
import org.telegram.ui.ActionBar.Theme;

import java.util.Collections;
import java.util.List;

public final class VeilGramArchiveActivity extends BaseFragment {
    private List<VeilGramArchive.Record> records = Collections.emptyList();

    @Override
    public View createView(Context context) {
        actionBar.setTitle("Удалённые сообщения");
        actionBar.setBackButtonImage(R.drawable.ic_ab_back);
        actionBar.setActionBarMenuOnItemClick(new ActionBar.ActionBarMenuOnItemClick() {
            @Override
            public void onItemClick(int id) {
                if (id == -1) finishFragment();
            }
        });

        FrameLayout root = new FrameLayout(context);
        root.setBackgroundColor(Theme.getColor(Theme.key_windowBackgroundWhite));
        ListView list = new ListView(context);
        TextView empty = new TextView(context);
        empty.setGravity(Gravity.CENTER);
        empty.setTextColor(Theme.getColor(Theme.key_windowBackgroundWhiteGrayText));
        empty.setText("Загрузка…");
        root.addView(list, new FrameLayout.LayoutParams(-1, -1));
        root.addView(empty, new FrameLayout.LayoutParams(-1, -1));

        BaseAdapter adapter = new BaseAdapter() {
            @Override public int getCount() { return records.size(); }
            @Override public Object getItem(int position) { return records.get(position); }
            @Override public long getItemId(int position) { return position; }

            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                ArchiveRow row = convertView instanceof ArchiveRow ? (ArchiveRow) convertView : new ArchiveRow(context);
                VeilGramArchive.Record record = records.get(position);
                row.title.setText(record.chat + " · " + DateUtils.formatDateTime(context, record.date * 1000L,
                        DateUtils.FORMAT_SHOW_DATE | DateUtils.FORMAT_SHOW_TIME));
                row.body.setText(record.text);
                return row;
            }
        };
        list.setEmptyView(empty);
        list.setAdapter(adapter);
        list.setOnItemClickListener((parent, view, position, id) -> {
            VeilGramArchive.Record record = records.get(position);
            showDialog(new AlertDialog.Builder(context).setTitle(record.chat).setMessage(record.text)
                    .setPositiveButton("ОК", null).create());
        });
        fragmentView = root;
        VeilGramArchive.load(getCurrentAccount(), (result, failed) -> {
            if (fragmentView != root) return;
            records = result;
            empty.setText(failed ? "Не удалось загрузить архив" : "Архив пока пуст");
            adapter.notifyDataSetChanged();
        });
        return root;
    }

    private static final class ArchiveRow extends LinearLayout {
        final TextView title;
        final TextView body;

        ArchiveRow(Context context) {
            super(context);
            setOrientation(VERTICAL);
            int inset = AndroidUtilities.dp(16);
            setPadding(inset, inset, inset, inset);
            title = new TextView(context);
            title.setTextSize(13);
            title.setTextColor(Theme.getColor(Theme.key_windowBackgroundWhiteGrayText));
            body = new TextView(context);
            body.setTextSize(16);
            body.setTextColor(Theme.getColor(Theme.key_windowBackgroundWhiteBlackText));
            body.setMaxLines(3);
            body.setEllipsize(TextUtils.TruncateAt.END);
            addView(title);
            addView(body);
        }
    }
}
