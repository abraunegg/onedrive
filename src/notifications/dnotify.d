module dnotify;

private {
    import std.string : toStringz;
    import std.conv : to;
    import std.traits : isPointer, isArray;
    import std.variant : Variant;
    import std.array : appender;
    
    import deimos.notify.notify;
}

public import deimos.notify.notify : NOTIFY_EXPIRES_DEFAULT, NOTIFY_EXPIRES_NEVER,
                                     NotifyUrgency;


version(NoPragma) {
} else {
    pragma(lib, "notify");
    pragma(lib, "gmodule");
    pragma(lib, "glib-2.0");
}

extern (C) {
    private void g_free(void* mem);
    private void g_list_free(GList* glist);
}

version(NoGdk) {
} else {
    version(NoPragma) {
    } else {
        pragma(lib, "gdk_pixbuf");
    }

    private:
    extern (C) {
        GdkPixbuf* gdk_pixbuf_new_from_file(const(char)* filename, GError **error);
    }
}

class NotificationError : Exception {
    string message;
    GError* gerror;
    
    this(GError* gerror) {
        this.message = to!(string)(gerror.message);
        this.gerror = gerror;
        
        super(this.message);
    }

    this(string message) {
        this.message = message;

        super(message);
    }
}

bool check_availability() {
    // notify_init might return without dbus server actually started
    // try to check for running dbus server
    char **ret_name;
    char **ret_vendor;
    char **ret_version;
    char **ret_spec_version;
    bool ret;
    try {
	return notify_get_server_info(ret_name, ret_vendor, ret_version, ret_spec_version);
    } catch (NotificationError e) {
	throw new NotificationError("Cannot find dbus server!");
    }
}

void init(in char[] name) {
    notify_init(name.toStringz());
}

alias notify_is_initted is_initted;
alias notify_uninit uninit;

static this() {
    init(__FILE__);
}

static ~this() {
    uninit();
}

string get_app_name() {
    return to!(string)(notify_get_app_name());
}

void set_app_name(in char[] app_name) {
    notify_set_app_name(app_name.toStringz());
}

string[] get_server_caps() {
    auto result = appender!(string[])();
    
    GList* list = notify_get_server_caps();
    if(list !is null) {
        for(GList* c = list; c !is null; c = c.next) {
            result.put(to!(string)(cast(char*)c.data));
            g_free(c.data);
        }

        g_list_free(list);
    }

    return result.data;
}

struct ServerInfo {
    string name;
    string vendor;
    string version_;
    string spec_version;
}

ServerInfo get_server_info() {
    char* name;
    char* vendor;
    char* version_;
    char* spec_version;
    notify_get_server_info(&name, &vendor, &version_, &spec_version);

    scope(exit) {
        g_free(name);
        g_free(vendor);
        g_free(version_);
        g_free(spec_version);
    }

    return ServerInfo(to!string(name), to!string(vendor), to!string(version_), to!string(spec_version));
}


struct Action {
    const(char[]) id;
    const(char[]) label;
    NotifyActionCallback callback;
    void* user_ptr;
}


class Notification {
    NotifyNotification* notify_notification;
    
    const(char)[] summary;
    const(char)[] body_;
    const(char)[] icon;

    bool closed = true;
    
    private int _timeout = NOTIFY_EXPIRES_DEFAULT;
    const(char)[] _category;
    NotifyUrgency _urgency;
    GdkPixbuf* _image;
    Variant[const(char)[]] _hints;
    const(char)[] _app_name;
    Action[] _actions;

    this(in char[] summary, in char[] body_, in char[] icon="")
        in { assert(is_initted(), "call dnotify.init() before using Notification"); }
        do {
            this.summary = summary;
            this.body_ = body_;
            this.icon = icon;
            notify_notification = notify_notification_new(summary.toStringz(), body_.toStringz(), icon.toStringz());
        }

    bool update(in char[] summary, in char[] body_, in char[] icon="") {
        this.summary = summary;
        this.body_ = body_;
        this.icon = icon;
        return notify_notification_update(notify_notification, summary.toStringz(), body_.toStringz(), icon.toStringz());
    }

    void show() {
        GError* ge;

        if(!notify_notification_show(notify_notification, &ge)) {
            throw new NotificationError(ge);
        }
    }

    @property int timeout() { return _timeout; }
    @property void timeout(int timeout) {
        this._timeout = timeout;
        notify_notification_set_timeout(notify_notification, timeout);
    }

    @property const(char[]) category() { return _category; }
    @property void category(in char[] category) {
        this._category = category;
        notify_notification_set_category(notify_notification, category.toStringz());
    }

    @property NotifyUrgency urgency() { return _urgency; }
    @property void urgency(NotifyUrgency urgency) {
        this._urgency = urgency;
        notify_notification_set_urgency(notify_notification, urgency);
    }


    void set_image(GdkPixbuf* pixbuf) {
        notify_notification_set_image_from_pixbuf(notify_notification, pixbuf);
        //_image = pixbuf;
    }
    
    version(NoGdk) {
    } else {
        void set_image(in char[] filename) { 
            GError* ge;
            // TODO: free pixbuf
            GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(filename.toStringz(), &ge);

            if(pixbuf is null) {
                if(ge is null) {
                    throw new NotificationError("Unable to load file: " ~ filename.idup);
                } else {
                    throw new NotificationError(ge);
                }
            }
            assert(notify_notification !is null);
            notify_notification_set_image_from_pixbuf(notify_notification, pixbuf); // TODO: fix segfault
            //_image = pixbuf;
        }
    }

    @property GdkPixbuf* image() { return _image; }
    
    // using deprecated set_hint_* functions (GVariant is an opaque structure, which needs the glib)
    void set_hint(T)(in char[] key, T value) {
        static if(is(T == int)) {
            notify_notification_set_hint_int32(notify_notification, key, value);
        } else static if(is(T == uint)) {
            notify_notification_set_hint_uint32(notify_notification, key, value);
        } else static if(is(T == double)) {
            notify_notification_set_hint_double(notify_notification, key, value);
        } else static if(is(T : const(char)[])) {
            notify_notification_set_hint_string(notify_notification, key, value.toStringz());
        } else static if(is(T == ubyte)) {
            notify_notification_set_hint_byte(notify_notification, key, value);
        } else static if(is(T == ubyte[])) {
            notify_notification_set_hint_byte_array(notify_notification, key, value.ptr, value.length);
        } else {
            static assert(false, "unsupported value for Notification.set_hint");
        }

        _hints[key] = Variant(value);
    }

    // unset hint?

    Variant get_hint(in char[] key) {
        return _hints[key];
    }

    @property const(char)[] app_name() { return _app_name; }
    @property void app_name(in char[] name) {
        this._app_name = app_name;
        notify_notification_set_app_name(notify_notification, app_name.toStringz());
    }

    void add_action(T)(in char[] action, in char[] label, NotifyActionCallback callback, T user_data) {
        static if(isPointer!T) {
            void* user_ptr = cast(void*)user_data;
        } else static if(isArray!T) {
            void* user_ptr = cast(void*)user_data.ptr;
        } else {
            void* user_ptr = cast(void*)&user_data;
        }

        notify_notification_add_action(notify_notification, action.toStringz(), label.toStringz(),
                                       callback, user_ptr, null);

        _actions ~= Action(action, label, callback, user_ptr);
    }

    void add_action()(Action action) {
        notify_notification_add_action(notify_notification, action.id.toStringz(), action.label.toStringz(),
                                       action.callback, action.user_ptr, null);

        _actions ~= action;
    }

    @property Action[] actions() { return _actions; }
    
    void clear_actions() {
        notify_notification_clear_actions(notify_notification);
    }

    void close() {
        GError* ge;
        
        if(!notify_notification_close(notify_notification, &ge)) {
            throw new NotificationError(ge);
        }
    }

    @property int closed_reason() {
        return notify_notification_get_closed_reason(notify_notification);
    }
}


version(TestMain) {
    import std.stdio;
    
    void main() {
        writeln(get_app_name());
        set_app_name("bla");
        writeln(get_app_name());
        writeln(get_server_caps());
        writeln(get_server_info());
        
        auto n = new Notification("foo", "bar", "notification-message-im");
        n.timeout = 3;
        n.show();
    }
}
