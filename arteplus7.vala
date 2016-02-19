/*
 * Totem Arte Plugin allows you to watch streams from arte.tv
 * Copyright (C) 2009, 2010, 2011, 2012 Simon Wenner <simon@wenner.ch>
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
 * The Totem Arte Plugin project hereby grants permission for non-GPL compatible
 * GStreamer plugins to be used and distributed together with GStreamer, Totem
 * and Totem Arte Plugin. This permission is above and beyond the permissions
 * granted by the GPL license by which Totem Arte Plugin is covered.
 * If you modify this code, you may extend this exception to your version of the
 * code, but you are not obligated to do so. If you do not wish to do so,
 * delete this exception statement from your version.
 *
 */

using GLib;
using Soup;
using Totem;
using Gtk;
using Peas;
using PeasGtk;

public enum VideoQuality
{
    // The strange ordering is for keeping compatibility with saved settings
    UNKNOWN = 0,
    MEDIUM, // 400p
    HD, // 720p
    LOW, // 220p
    HIGH // 400p, much better audio/video bitrate than medium
}

public enum Language
{
    UNKNOWN = 0,
    FRENCH,
    GERMAN
}

public string USER_AGENT;
private const string USER_AGENT_TMPL =
    "Mozilla/5.0 (X11; Linux x86_64; rv:%d.0) Gecko/20100101 Firefox/%d.0";
public const string DCONF_ID = "org.gnome.Totem.arteplus7";
public const string DCONF_HTTP_PROXY = "org.gnome.system.proxy.http";
public const string CACHE_PATH_SUFFIX = "/totem/plugins/arteplus7/";
public const int THUMBNAIL_WIDTH = 160;
public const string DEFAULT_THUMBNAIL = "/usr/share/totem/plugins/arteplus7/arteplus7-default.png";
public bool use_proxy = false;
public Soup.URI proxy_uri;
public string proxy_username;
public string proxy_password;

public static Soup.SessionAsync create_session ()
{
    Soup.SessionAsync session;
    if (use_proxy) {
        session = new Soup.SessionAsync.with_options (
                Soup.SESSION_USER_AGENT, USER_AGENT,
                Soup.SESSION_PROXY_URI, proxy_uri, null);

        session.authenticate.connect((sess, msg, auth, retrying) => {
            /* check if authentication is needed */
            if (!retrying) {
                auth.authenticate (proxy_username, proxy_password);
            } else {
                GLib.warning ("Proxy authentication failed!\n");
            }
        });
    } else {
        session = new Soup.SessionAsync.with_options (
                Soup.SESSION_USER_AGENT, USER_AGENT, null);
    }
    session.timeout = 10; /* 10 seconds timeout, until we give up and show an error message */
    return session;
}

public void debug (string format, ...)
{
#if DEBUG_MESSAGES
    var args = va_list ();
    GLib.logv ("TotemArte", GLib.LogLevelFlags.LEVEL_DEBUG, format, args);
#endif
}

class ArtePlugin : Peas.Activatable, PeasGtk.Configurable, Peas.ExtensionBase
{
    public GLib.Object object { owned get; construct; }
    private Totem.Object t;
    private Gtk.Entry search_entry; /* search field with buttons inside */
    private VideoListView tree_view; /* list of movie thumbnails */
    private ArteParser parsers[2]; /* array of parsers */
    private GLib.Settings settings;
    private GLib.Settings proxy_settings;
    private Cache cache; /* image thumbnail cache */
    private Language language;
    private VideoQuality quality;
    private ConnectionStatus cs;

    private delegate void VoidFunction ();

    public ArtePlugin ()
    {
        /* constructor chain up hint */
        GLib.Object ();
    }

    construct
    {
        /* Debug log handling */
#if DEBUG_MESSAGES
        GLib.Log.set_handler ("TotemArte", GLib.LogLevelFlags.LEVEL_DEBUG,
        (domain, levels, msg) => {
                stdout.printf ("%s-DEBUG: %s\n", domain, msg);
            });
#endif

        this.settings = new GLib.Settings (DCONF_ID);
        this.proxy_settings = new GLib.Settings (DCONF_HTTP_PROXY);
        load_properties ();
    }

    /* Gir doesn't allow marking functions as non-abstract */
    public void update_state () {}

    public void activate ()
    {
        this.cs = new ConnectionStatus ();

        /* Generate the user-agent */
        TimeVal tv = TimeVal ();
        tv.get_current_time ();
        /* First, we need to compute the number of weeks since Epoch */
        int weeks = (int) tv.tv_sec / ( 60 * 60 * 24 * 7 );
        /* We know there is a new Firefox release each 6 weeks.
           And we know Firefox 11.0 was released the 03/13/2012, which
           corresponds to 2201 weeks after Epoch.
           We add a 3 weeks margin and then we can compute the version number! */
        int version = 11 + (weeks - (2201 + 3)) / 6;
        USER_AGENT = USER_AGENT_TMPL.printf(version, version);
        debug (USER_AGENT);

        settings.changed.connect ((key) => { on_settings_changed (key); });
        proxy_settings.changed.connect ((key) => { on_settings_changed (key); });

        t = object as Totem.Object;
        cache = new Cache (Environment.get_user_cache_dir ()
             + CACHE_PATH_SUFFIX);
        parsers[0] = new ArteJSONParser ();
        parsers[1] = new ArteRSSParser ();
        tree_view = new VideoListView (cache);

        tree_view.video_selected.connect (callback_video_selected);

        var scroll_win = new Gtk.ScrolledWindow (null, null);
        scroll_win.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        scroll_win.set_shadow_type (ShadowType.IN);
        scroll_win.add (tree_view);

        /* add a search entry with a refresh and a cleanup icon */
        search_entry = new Gtk.Entry ();
        search_entry.set_icon_from_icon_name (Gtk.EntryIconPosition.PRIMARY,
                "view-refresh");
        search_entry.set_icon_tooltip_text (Gtk.EntryIconPosition.PRIMARY,
                _("Reload feed"));
        search_entry.set_icon_from_icon_name (Gtk.EntryIconPosition.SECONDARY,
                "edit-clear");
        search_entry.set_icon_tooltip_text (Gtk.EntryIconPosition.SECONDARY,
                _("Clear the search text"));
        search_entry.set_icon_sensitive (Gtk.EntryIconPosition.SECONDARY, false);
        /* search as you type */
        search_entry.changed.connect ((widget) => {
            Gtk.Entry entry = (Gtk.Entry) widget;
            entry.set_icon_sensitive (Gtk.EntryIconPosition.SECONDARY,
                    (entry.get_text () != ""));

            var filter = entry.get_text ().down ();
            tree_view.set_filter(filter);
        });
        /* set focus to the first video on return */
        search_entry.activate.connect ((entry) => {
            tree_view.set_cursor(new TreePath.first (), null, false);
            tree_view.grab_focus ();
        });
        /* cleanup or refresh on click */
        search_entry.icon_press.connect ((entry, position, event) => {
            if (position == Gtk.EntryIconPosition.PRIMARY)
                callback_refresh_rss_feed ();
            else
                entry.set_text ("");
        });

        var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        main_box.pack_start (search_entry, false, false, 0);
        main_box.pack_start (scroll_win, true, true, 0);
        main_box.show_all ();

        t.add_sidebar_page ("arte", _("Arte+7"), main_box);
        GLib.Idle.add (refresh_rss_feed);

        /* delete outdated files in the cache */
        GLib.Idle.add (() => {
            cache.delete_cruft ();
            return false;
        });

        /* Refresh the feed on pressing 'F5' */
        var window = t.get_main_window ();
        window.key_press_event.connect (callback_F5_pressed);

        /* refresh the feed if we were offline and it has not been loaded */
        this.cs.status_changed.connect ((is_online) => {
            debug ("ConnectionStatus changed: is_online = %d", (int)is_online);
            if (is_online && tree_view.get_size () < 2) {
                // delay it by 3 seconds to avoid timing issues
                GLib.Timeout.add_seconds (3, refresh_rss_feed);
            }
        });
    }

    public void deactivate ()
    {
        /* Disable connection updates */
        this.cs = null;
        /* Remove the 'F5' key event handler */
        var window = t.get_main_window ();
        window.key_press_event.disconnect (callback_F5_pressed);
        /* Remove the plugin tab */
        t.remove_sidebar_page ("arte");
    }

    /* This code must be independent from the rest of the plugin */
    public Gtk.Widget create_configure_widget ()
    {
        var langs = new Gtk.ComboBoxText ();
        langs.append_text (_("French"));
        langs.append_text (_("German"));
        if (language == Language.GERMAN)
            langs.set_active (1);
        else
            langs.set_active (0);

        langs.changed.connect (() => {
            Language last = language;
            if (langs.get_active () == 1) {
                language = Language.GERMAN;
            } else {
                language = Language.FRENCH;
            }
            if (last != language) {
                if (!settings.set_enum ("language", (int) language))
                    GLib.warning ("Storing the language setting failed.");
            };
        });

        settings.changed["language"].connect (() => {
            var l = settings.get_enum ("language");
            if (l == Language.GERMAN) {
                language = Language.GERMAN;
                langs.set_active (1);
            } else {
                language = Language.FRENCH;
                langs.set_active (0);
            }
        });

        var quali_radio_low = new Gtk.RadioButton.with_mnemonic (null, _("l_ow (220p)"));
        var quali_radio_medium = new Gtk.RadioButton.with_mnemonic_from_widget (
                quali_radio_low, _("_medium (400p)"));
        var quali_radio_high = new Gtk.RadioButton.with_mnemonic_from_widget (
                quali_radio_medium, _("_high (400p, better encoding)"));
        var quali_radio_hd = new Gtk.RadioButton.with_mnemonic_from_widget (
                quali_radio_high, _("H_D (720p)"));
        switch (quality) {
            case VideoQuality.LOW:
                quali_radio_low.set_active (true);
                break;
            case VideoQuality.MEDIUM:
                quali_radio_medium.set_active (true);
                break;
            case VideoQuality.HIGH:
                quali_radio_high.set_active (true);
                break;
            default:
                quali_radio_hd.set_active (true);
                break;
        }

        /* reusable lambda function */
        VoidFunction quality_toggle_clicked = () => {
            VideoQuality last = this.quality;
            if (quali_radio_low.get_active ())
                this.quality = VideoQuality.LOW;
            else if (quali_radio_medium.get_active ())
                this.quality = VideoQuality.MEDIUM;
            else if (quali_radio_high.get_active ())
                this.quality = VideoQuality.HIGH;
            else
                this.quality = VideoQuality.HD;

            if (last != this.quality) {
                if (!settings.set_enum ("quality", (int) this.quality))
                    GLib.warning ("Storing the quality setting failed.");
            }
        };

        quali_radio_low.toggled.connect (() => { quality_toggle_clicked(); });
        quali_radio_medium.toggled.connect (() => { quality_toggle_clicked(); });
        quali_radio_high.toggled.connect (() => { quality_toggle_clicked(); });
        quali_radio_hd.toggled.connect (() => { quality_toggle_clicked(); });

        settings.changed["quality"].connect (() => {
            var q = settings.get_enum ("quality");
            if (q == VideoQuality.LOW) {
                quality = VideoQuality.LOW;
                quali_radio_low.set_active (true);
            } else if (q == VideoQuality.MEDIUM) {
                quality = VideoQuality.MEDIUM;
                quali_radio_medium.set_active (true);
            } else if (q == VideoQuality.HIGH) {
                quality = VideoQuality.HIGH;
                quali_radio_high.set_active (true);
            } else {
                quality = VideoQuality.HD;
                quali_radio_hd.set_active (true);
            }
        });

        var langs_label = new Gtk.Label.with_mnemonic (_("_Language:"));
        langs_label.set_mnemonic_widget (langs);
        langs.mnemonic_activate.connect (() => { langs.popup(); return true; });

        var langs_box = new Box (Gtk.Orientation.HORIZONTAL, 20);
        langs_box.pack_start (langs_label, false, true, 0);
        langs_box.pack_start (langs, true, true, 0);

        var quali_label = new Gtk.Label (_("Video quality:"));
        var quali_box = new Box (Gtk.Orientation.HORIZONTAL, 20);
        quali_box.pack_start (quali_label, false, true, 0);
        quali_box.pack_start (quali_radio_low, false, true, 0);
        quali_box.pack_start (quali_radio_medium, false, true, 0);
        quali_box.pack_start (quali_radio_high, false, true, 0);
        quali_box.pack_start (quali_radio_hd, true, true, 0);

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 20);
        vbox.pack_start (langs_box, false, true, 0);
        vbox.pack_start (quali_box, false, true, 0);

        return vbox;
    }

    private bool refresh_rss_feed ()
    {
        if (!this.cs.is_online) {
            // display offline message
            tree_view.display_message (_("No internet connection."));

            // invalidate all existing videos
            tree_view.clear ();

            return false;
        }

        uint parse_errors = 0;
        uint network_errors = 0;
        uint error_threshold = 0;

        search_entry.set_sensitive (false);

        debug ("Refreshing Video Feed...");

        /* display loading message */
        tree_view.display_message (_("Loading..."));

        /* remove all existing videos */
        tree_view.clear ();

        // download and parse feeds
        // try parsers one by one until enough videos are extracted
        for (int i=0; i<parsers.length; i++)
        {
            var p = parsers[i];
            p.reset ();
            parse_errors = 0;
            network_errors = 0;
            error_threshold = p.get_error_threshold ();

            // get all data chunks of a parser
            while (p.has_data)
            {
                try {
                    // parse
                    unowned GLib.SList<Video> videos = p.parse (language);

                    // add videos to the list
                    tree_view.add_videos (videos);

                } catch (MarkupError e) {
                    parse_errors++;
                    GLib.critical ("XML Parse Error: %s", e.message);
                } catch (IOError e) {
                    network_errors++;
                    GLib.critical ("Network problems: %s", e.message);
                }

                // request the next chunk of data
                p.advance ();

                // leave the loop if we got too many errors
                if (parse_errors >= error_threshold || network_errors >= error_threshold)
                    break;
            }

            // the RSS feeds have duplicates
            if (p.has_duplicates ())
                tree_view.check_and_remove_duplicates ();

            // try to recover if we failed to parse some thumbnails URI
            tree_view.check_and_download_missing_image_urls ();

            // leave the loop if we got enought videos
            if (parse_errors < error_threshold && network_errors < error_threshold)
                break;
        }

        /* while parsing we only used images from the cache */
        tree_view.check_and_download_missing_thumbnails ();

        debug ("Video Feed loaded, video count: %u", tree_view.get_size ());

        // show user visible error messages
        if (parse_errors > error_threshold)
        {
            t.action_error (_("Markup Parser Error"),
                    _("Sorry, the plugin could not parse the Arte video feed."));
        } else if (network_errors > error_threshold) {
            t.action_error (_("Network problem"),
                    _("Sorry, the plugin could not download the Arte video feed.\nPlease verify your network settings and (if any) your proxy settings."));
        }

        search_entry.set_sensitive (true);
        search_entry.grab_focus ();

        return false;
    }

    /* loads properties from dconf */
    private void load_properties ()
    {
        string parsed_proxy_uri = "";
        int proxy_port;

        quality = (VideoQuality) settings.get_enum ("quality");
        language = (Language) settings.get_enum ("language");
        use_proxy = proxy_settings.get_boolean ("enabled");

        if (use_proxy) {
            parsed_proxy_uri = proxy_settings.get_string ("host");
            proxy_port = proxy_settings.get_int ("port");
            if (parsed_proxy_uri == "") {
                use_proxy = false; /* necessary to prevent a crash in this case */
            } else {
                proxy_uri = new Soup.URI ("http://" + parsed_proxy_uri + ":" + proxy_port.to_string());
                debug ("Using proxy: %s", proxy_uri.to_string (false));
                proxy_username = proxy_settings.get_string ("authentication-user");
                proxy_password = proxy_settings.get_string ("authentication-password");
            }
        }

        if (language == Language.UNKNOWN) { /* Try to guess user prefer language at first run */
            var env_lang = Environment.get_variable ("LANG");
            if (env_lang != null && env_lang.substring (0,2) == "de") {
                language = Language.GERMAN;
            } else {
                language = Language.FRENCH; /* Otherwise, French is the default language */
            }
            if (!settings.set_enum ("language", (int) language))
                GLib.warning ("Storing the language setting failed.");
        }

        if (quality == VideoQuality.UNKNOWN) {
            quality = VideoQuality.HD; // default quality
            if (!settings.set_enum ("quality", (int) quality))
                GLib.warning ("Storing the quality setting failed.");
        }
    }

    private void on_settings_changed (string key)
    {
        if (key == "quality")
            load_properties ();
        else { /* Reload the feed if the language or proxy settings changed */
            load_properties ();
            GLib.Idle.add (refresh_rss_feed);
        }
    }

    private void callback_video_selected (string url, string title)
    {
        string stream_url = null;
        try {
            stream_url = get_stream_url (url, quality, language);
        } catch (ExtractionError e) {
            if(e is ExtractionError.ACCESS_RESTRICTED) {
                /* This video access is restricted */
                t.action_error (_("This video access is restricted"),
                        _("It seems that, because of its content, this video can only be watched in a precise time interval.\n\nYou may retry later, for example between 11 PM and 5 AM."));
            } else if(e is ExtractionError.STREAM_NOT_READY) {
                /* The video is part of the XML/RSS feed but no stream is available yet */
                t.action_error (_("This video is not available yet"),
                        _("Sorry, the plugin could not find any stream URL.\nIt seems that this video is not available yet, even on the Arte web-player.\n\nPlease retry later."));
            } else if (e is ExtractionError.DOWNLOAD_FAILED) {
                /* Network problems */
                t.action_error (_("Video URL Extraction Error"),
                        _("Sorry, the plugin could not extract a valid stream URL.\nPlease verify your network settings and (if any) your proxy settings."));
            } else {
                /* ExtractionError.EXTRACTION_ERROR or an unspecified error */
                t.action_error (_("Video URL Extraction Error"),
                        _("Sorry, the plugin could not extract a valid stream URL.\nPerhaps this stream is not yet available, you may retry in a few minutes.\n\nBe aware that this service is only available for IPs within Austria, Belgium, Germany, France and Switzerland."));
            }
            return;
        }

        t.add_to_playlist_and_play (stream_url, title, false);
    }

    private void callback_refresh_rss_feed ()
    {
        GLib.Idle.add (refresh_rss_feed);
    }

    private bool callback_F5_pressed (Gdk.EventKey event)
    {
        string key = Gdk.keyval_name (event.keyval);
        if (key == "F5")
            callback_refresh_rss_feed ();

        /* propagate the signal to the next handler */
        return false;
    }

    private string get_stream_url (string page_url, VideoQuality q, Language lang)
        throws ExtractionError
    {
        var extractor = new RTMPStreamUrlExtractor ();
        return extractor.get_url (q, lang, page_url);
    }
}

[ModuleInit]
public void peas_register_types (GLib.TypeModule module)
{
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof(Peas.Activatable), typeof(ArtePlugin));
    objmodule.register_extension_type (typeof(PeasGtk.Configurable), typeof(ArtePlugin));
}
