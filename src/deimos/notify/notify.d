/**
 * Copyright (C) 2004-2006 Christian Hammond
 * Copyright (C) 2010 Red Hat, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA  02111-1307, USA.
 */

module deimos.notify.notify;


enum NOTIFY_VERSION_MAJOR = 0;
enum NOTIFY_VERSION_MINOR = 7;
enum NOTIFY_VERSION_MICRO = 5;

template NOTIFY_CHECK_VERSION(int major, int minor, int micro) {
    enum NOTIFY_CHECK_VERSION = ((NOTIFY_VERSION_MAJOR > major) ||
            (NOTIFY_VERSION_MAJOR == major && NOTIFY_VERSION_MINOR > minor) ||
            (NOTIFY_VERSION_MAJOR == major && NOTIFY_VERSION_MINOR == minor &&
             NOTIFY_VERSION_MICRO >= micro));
}


alias ulong GType;
alias void function(void*) GFreeFunc;

struct GError {
  uint domain;
  int code;
  char* message;
}

struct GList {
  void* data;
  GList* next;
  GList* prev;
}

// dummies
struct GdkPixbuf {}
struct GObject {}
struct GObjectClass {}
struct GVariant {}

GType notify_urgency_get_type();

/**
 * NOTIFY_EXPIRES_DEFAULT:
 *
 * The default expiration time on a notification.
 */
enum NOTIFY_EXPIRES_DEFAULT = -1;

/**
 * NOTIFY_EXPIRES_NEVER:
 *
 * The notification never expires. It stays open until closed by the calling API
 * or the user.
 */
enum NOTIFY_EXPIRES_NEVER = 0;

// #define NOTIFY_TYPE_NOTIFICATION         (notify_notification_get_type ())
// #define NOTIFY_NOTIFICATION(o)           (G_TYPE_CHECK_INSTANCE_CAST ((o), NOTIFY_TYPE_NOTIFICATION, NotifyNotification))
// #define NOTIFY_NOTIFICATION_CLASS(k)     (G_TYPE_CHECK_CLASS_CAST((k), NOTIFY_TYPE_NOTIFICATION, NotifyNotificationClass))
// #define NOTIFY_IS_NOTIFICATION(o)        (G_TYPE_CHECK_INSTANCE_TYPE ((o), NOTIFY_TYPE_NOTIFICATION))
// #define NOTIFY_IS_NOTIFICATION_CLASS(k)  (G_TYPE_CHECK_CLASS_TYPE ((k), NOTIFY_TYPE_NOTIFICATION))
// #define NOTIFY_NOTIFICATION_GET_CLASS(o) (G_TYPE_INSTANCE_GET_CLASS ((o), NOTIFY_TYPE_NOTIFICATION, NotifyNotificationClass))

extern (C) {
    struct NotifyNotificationPrivate;
    
    struct NotifyNotification {
            /*< private >*/
            GObject      parent_object;

            NotifyNotificationPrivate *priv;
    }

    struct NotifyNotificationClass {
            GObjectClass    parent_class;

            /* Signals */
            void function(NotifyNotification *notification) closed;
    }


    /**
     * NotifyUrgency:
     * @NOTIFY_URGENCY_LOW: Low urgency. Used for unimportant notifications.
     * @NOTIFY_URGENCY_NORMAL: Normal urgency. Used for most standard notifications.
     * @NOTIFY_URGENCY_CRITICAL: Critical urgency. Used for very important notifications.
     *
     * The urgency level of the notification.
     */
    enum NotifyUrgency {
            NOTIFY_URGENCY_LOW,
            NOTIFY_URGENCY_NORMAL,
            NOTIFY_URGENCY_CRITICAL,

    }

    /**
     * NotifyActionCallback:
     * @notification:
     * @action:
     * @user_data:
     *
     * An action callback function.
     */
    alias void function(NotifyNotification* notification, char* action, void* user_data) NotifyActionCallback;


    GType notify_notification_get_type();

    NotifyNotification* notify_notification_new(const(char)* summary, const(char)* body_, const(char)* icon);

    bool notify_notification_update(NotifyNotification* notification, const(char)* summary, const(char)* body_, const(char)* icon);

    bool notify_notification_show(NotifyNotification* notification, GError** error);

    void notify_notification_set_timeout(NotifyNotification* notification, int timeout);

    void notify_notification_set_category(NotifyNotification* notification, const(char)* category);

    void notify_notification_set_urgency(NotifyNotification* notification, NotifyUrgency urgency);

    void notify_notification_set_image_from_pixbuf(NotifyNotification* notification, GdkPixbuf* pixbuf);

    void notify_notification_set_icon_from_pixbuf(NotifyNotification* notification, GdkPixbuf* icon);

    void notify_notification_set_hint_int32(NotifyNotification* notification, const(char)* key, int value);
    void notify_notification_set_hint_uint32(NotifyNotification* notification, const(char)* key, uint value);

    void notify_notification_set_hint_double(NotifyNotification* notification, const(char)* key, double value);

    void notify_notification_set_hint_string(NotifyNotification* notification, const(char)* key, const(char)* value);

    void notify_notification_set_hint_byte(NotifyNotification* notification, const(char)* key, ubyte value);

    void notify_notification_set_hint_byte_array(NotifyNotification* notification, const(char)* key, const(ubyte)* value, ulong len);

    void notify_notification_set_hint(NotifyNotification* notification, const(char)* key, GVariant* value);

    void notify_notification_set_app_name(NotifyNotification* notification, const(char)* app_name);

    void notify_notification_clear_hints(NotifyNotification* notification);

    void notify_notification_add_action(NotifyNotification* notification, const(char)* action, const(char)* label,
                                        NotifyActionCallback callback, void* user_data, GFreeFunc free_func);

    void notify_notification_clear_actions(NotifyNotification* notification);
    bool notify_notification_close(NotifyNotification* notification, GError** error);

    int notify_notification_get_closed_reason(const NotifyNotification* notification);



    bool notify_init(const(char)* app_name);
    void notify_uninit();
    bool notify_is_initted();

    const(char)* notify_get_app_name();
    void notify_set_app_name(const(char)* app_name);

    GList *notify_get_server_caps();

    bool notify_get_server_info(char** ret_name, char** ret_vendor, char** ret_version, char** ret_spec_version);
}

version(MainTest) {
    import std.string;
    
    void main() {
        
        notify_init("test".toStringz());

        auto n = notify_notification_new("summary".toStringz(), "body".toStringz(), "none".toStringz());
        GError* ge;
        notify_notification_show(n, &ge);
        
        scope(success) notify_uninit();
    }
}
