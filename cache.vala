/*
 * Totem Arte Plugin allows you to watch streams from arte.tv
 * Copyright (C) 2010 Simon Wenner <simon@wenner.ch>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA.
 *
 */

using GLib;
using Gtk;
using Soup;

public class Cache : GLib.Object {
    public string cache_path {get; set;}
    private Soup.Session session;

    public Cache (string path)
    {
        cache_path = path;
        session = new Soup.SessionAsync.with_options (
                Soup.SESSION_USER_AGENT, USER_AGENT, null);

        /* create the caching directory */
        var dir = GLib.File.new_for_path (cache_path);
		if (!dir.query_exists (null)) {
			try {
				GLib.message ("Directory '%s' created", dir.get_path ());
				dir.make_directory_with_parents (null);
			} catch (Error e) {
				GLib.error ("Could not create caching directory.");
			}
		}
    }

    public string? get_data_path (string url)
    {
        /* check if file exists in cache */
        string file_path = cache_path
                + Checksum.compute_for_string (ChecksumType.MD5, url);

        var file = GLib.File.new_for_path (file_path);
		if (file.query_exists (null)) {
            return file_path;
        }

        /* get file from the the net */
        var msg = new Soup.Message ("GET", url);
        session.send_message (msg);

        if (msg.response_body.data == null) {
            return null;
        }

        /* store the file on disk */
        try {
            var file_stream = file.create (FileCreateFlags.REPLACE_DESTINATION, null);
            var data_stream = new DataOutputStream (file_stream);
            data_stream.write (msg.response_body.data,
                    (ssize_t) msg.response_body.length, null);

        } catch (Error e) {
            GLib.error ("%s", e.message);
        }

        return file_path;
    }

    public Gdk.Pixbuf? get_pixbuf (string url)
    {
        /* check if file exists in cache */
        string file_path = cache_path
                + Checksum.compute_for_string (ChecksumType.MD5, url);
        Gdk.Pixbuf pb = null;

        var file = GLib.File.new_for_path (file_path);
		if (file.query_exists (null)) {
            try {
                pb = new Gdk.Pixbuf.from_file (file_path);
            } catch (Error e) {
                GLib.error ("%s", e.message);
                return null;
            }
            return pb;
        }

        /* get file from the the net */
        var msg = new Soup.Message ("GET", url);
        session.send_message (msg);

        if (msg.response_body.data == null) {
            return null;
        }

        /* rescale it */
        var img_stream = new MemoryInputStream.from_data (msg.response_body.data,
                (ssize_t) msg.response_body.length, null);

        try {
            /* original size: 240px × 180px */
            pb = new Gdk.Pixbuf.from_stream_at_scale (img_stream,
                    THUMBNAIL_WIDTH, -1, true, null);
        } catch (GLib.Error e) {
            GLib.error ("%s", e.message);
            return null;
        }

        /* store the file on disk as PNG */
        try {
            pb.save (file_path, "png", null);
        } catch (Error e) {
            GLib.error ("%s", e.message);
        }

        return pb;
    }

    /* Delete files that were created more than x days ago. */
    public void delete_cruft (int days) {
        // Debug
        GLib.message ("Cache: Delete files that are older than %d days.", days);
        GLib.TimeVal now = TimeVal ();
        GLib.TimeVal mod_time = TimeVal ();
        now.get_current_time ();
        long deadline = now.tv_sec - days * 24 * 60 * 60;

        var directory = File.new_for_path (cache_path);
        try {
            var enumerator = directory.enumerate_children ("*",
                    GLib.FileQueryInfoFlags.NONE, null);

            GLib.FileInfo file_info;
            while ((file_info = enumerator.next_file (null)) != null) {
                file_info.get_modification_time (out mod_time);
                if (mod_time.tv_sec < deadline) {
                    var file = File.new_for_path (cache_path + file_info.get_name ());
                    file.delete (null);
                    // Debug
                    GLib.message ("Cache: Deleted: %s", file_info.get_name ());
                }
            }
            enumerator.close(null);

        } catch (Error e) {
            GLib.warning ("%s", e.message);
        }
    }
}