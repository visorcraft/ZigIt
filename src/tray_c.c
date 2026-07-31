#include "tray_c.h"

#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>
#include <stdlib.h>
#include <string.h>

struct ZigitTray {
    AppIndicator *indicator;
    GtkWidget *menu;
    /* Flags live on the heap with the tray — never on a Zig stack frame. */
    volatile int show;
    volatile int quit;
    volatile int capture_region;
    volatile int capture_window;
};

static void on_show(GtkMenuItem *item, gpointer user) {
    (void)item;
    ZigitTray *t = (ZigitTray *)user;
    t->show = 1;
}

static void on_quit(GtkMenuItem *item, gpointer user) {
    (void)item;
    ZigitTray *t = (ZigitTray *)user;
    t->quit = 1;
}

static void on_capture_region(GtkMenuItem *item, gpointer user) {
    (void)item;
    ZigitTray *t = (ZigitTray *)user;
    t->capture_region = 1;
}

static void on_capture_window(GtkMenuItem *item, gpointer user) {
    (void)item;
    ZigitTray *t = (ZigitTray *)user;
    t->capture_window = 1;
}

static void add_item(GtkWidget *menu, const char *label, GCallback cb, gpointer user) {
    GtkWidget *item = gtk_menu_item_new_with_label(label);
    g_signal_connect(item, "activate", cb, user);
    gtk_widget_show(item);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
}

/* Known-harmless tray noise we deliberately drop:
 *  - libayatana-appindicator deprecation (glib successor not packaged on Arch)
 *  - gtk_disable_setlocale ordering if a linked lib inits GTK first
 */
static int is_quiet_tray_message(const char *message) {
    if (!message)
        return 0;
    if (strstr(message, "libayatana-appindicator is deprecated") != NULL)
        return 1;
    if (strstr(message, "gtk_disable_setlocale") != NULL)
        return 1;
    return 0;
}

/* GLib 2.50+ structured logging path (GLib 2.88 uses this for g_warning). */
static GLogWriterOutput quiet_log_writer(GLogLevelFlags log_level,
                                         const GLogField *fields,
                                         gsize n_fields,
                                         gpointer user_data) {
    const char *message = NULL;
    gsize i;
    (void)user_data;
    for (i = 0; i < n_fields; i++) {
        if (fields[i].key && strcmp(fields[i].key, "MESSAGE") == 0) {
            message = (const char *)fields[i].value;
            break;
        }
    }
    if (is_quiet_tray_message(message))
        return G_LOG_WRITER_HANDLED;
    return g_log_writer_default(log_level, fields, n_fields, user_data);
}

/* Legacy domain-handler path (still used by some builds / domains). */
static void quiet_tray_warnings(const gchar *domain, GLogLevelFlags flags,
                                const gchar *message, gpointer user_data) {
    (void)domain;
    (void)flags;
    (void)user_data;
    if (is_quiet_tray_message(message))
        return;
    g_log_default_handler(domain, flags, message, user_data);
}

ZigitTray *zigit_tray_create(void) {
    /* Install filters before any GTK/AppIndicator init. */
    g_log_set_writer_func(quiet_log_writer, NULL, NULL);
    g_log_set_handler("libayatana-appindicator",
                      G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION,
                      quiet_tray_warnings, NULL);
    g_log_set_handler("Gtk",
                      G_LOG_LEVEL_WARNING | G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION,
                      quiet_tray_warnings, NULL);

    /* Prefer correct order when we own init. If GTK is already initialized
     * by a library constructor, this may warn — the filter above swallows it. */
    gtk_disable_setlocale();
    if (!gtk_init_check(NULL, NULL))
        return NULL;

    ZigitTray *t = calloc(1, sizeof(ZigitTray));
    if (!t)
        return NULL;

    t->indicator = app_indicator_new(
        "com.visorcraft.zigit",
        "com.visorcraft.zigit",
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    if (!t->indicator) {
        free(t);
        return NULL;
    }

    app_indicator_set_title(t->indicator, "ZigIt");
    app_indicator_set_icon_full(t->indicator, "com.visorcraft.zigit", "ZigIt");

    t->menu = gtk_menu_new();
    if (!t->menu || !GTK_IS_MENU(t->menu)) {
        g_object_unref(t->indicator);
        free(t);
        return NULL;
    }
    /* Own the floating ref; app_indicator_set_menu will ref_sink again. */
    g_object_ref_sink(t->menu);

    /* Pass tray itself as user_data so callbacks always hit heap storage. */
    GtkWidget *show_item = gtk_menu_item_new_with_label("Show ZigIt");
    g_signal_connect(show_item, "activate", G_CALLBACK(on_show), t);
    gtk_widget_show(show_item);
    gtk_menu_shell_append(GTK_MENU_SHELL(t->menu), show_item);

    add_item(t->menu, "Capture region", G_CALLBACK(on_capture_region), t);
    add_item(t->menu, "Capture window", G_CALLBACK(on_capture_window), t);
    GtkWidget *sep = gtk_separator_menu_item_new();
    gtk_widget_show(sep);
    gtk_menu_shell_append(GTK_MENU_SHELL(t->menu), sep);
    add_item(t->menu, "Quit", G_CALLBACK(on_quit), t);
    gtk_widget_show_all(t->menu);

    /* Menu before ACTIVE so the shell exports a complete StatusNotifierItem.
     * Ayatana asserts GTK_IS_MENU — never pass NULL (docs claim allow-none,
     * the implementation does not). */
    app_indicator_set_menu(t->indicator, GTK_MENU(t->menu));
    /* Left/middle click on the icon → same as "Show ZigIt". */
    app_indicator_set_secondary_activate_target(t->indicator, show_item);
    app_indicator_set_status(t->indicator, APP_INDICATOR_STATUS_ACTIVE);

    /* Keep a ref so the indicator stays alive for the process lifetime. */
    g_object_ref(t->indicator);
    return t;
}

void zigit_tray_destroy(ZigitTray *tray) {
    if (!tray)
        return;
    if (tray->indicator) {
        app_indicator_set_status(tray->indicator, APP_INDICATOR_STATUS_PASSIVE);
        /* Do not app_indicator_set_menu(..., NULL): libayatana-appindicator
         * g_return_if_fail(GTK_IS_MENU(menu)) and emits CRITICAL. The menu
         * is released when the indicator is unref'd. */
        g_object_unref(tray->indicator);
        tray->indicator = NULL;
    }
    if (tray->menu) {
        g_object_unref(tray->menu);
        tray->menu = NULL;
    }
    free(tray);
}

static int tray_has_action(const ZigitTray *t) {
    return t->show || t->quit || t->capture_region || t->capture_window;
}

/* Drain every pending GLib source (DBus, idle, timeouts). DBusMenu AboutToShow
 * is a multi-step handshake — one iteration is not enough. */
static void drain_glib(GMainContext *ctx) {
    int n = 0;
    while (g_main_context_pending(ctx) && n < 512) {
        g_main_context_iteration(ctx, FALSE);
        n++;
    }
}

void zigit_tray_poll(ZigitTray *tray) {
    if (!tray)
        return;
    GMainContext *ctx = g_main_context_default();
    drain_glib(ctx);
    /* Nested idles (common with GDBus) appear after a dispatch cycle. */
    g_main_context_iteration(ctx, FALSE);
    drain_glib(ctx);
}

static gboolean wait_timeout_cb(gpointer data) {
    volatile int *timed_out = (volatile int *)data;
    *timed_out = 1;
    return G_SOURCE_REMOVE;
}

void zigit_tray_wait(ZigitTray *tray, unsigned timeout_ms) {
    if (!tray) {
        g_usleep((gulong)timeout_ms * 1000u);
        return;
    }
    GMainContext *ctx = g_main_context_default();
    /* Bound the block so the Zig loop can still observe instance socket etc. */
    volatile int timed_out = 0;
    guint id = g_timeout_add_full(G_PRIORITY_DEFAULT, timeout_ms, wait_timeout_cb,
                                  (gpointer)&timed_out, NULL);

    drain_glib(ctx);

    /* Block on GLib (DBus/SNI/DBusMenu) instead of sleeping in GLFW — that was
     * starving the menu handshake and making open/activate feel multi-second. */
    while (!timed_out && !tray_has_action(tray)) {
        g_main_context_iteration(ctx, TRUE);
        drain_glib(ctx);
    }

    if (!timed_out)
        g_source_remove(id);
    drain_glib(ctx);
}

static bool take_flag(volatile int *f) {
    if (*f) {
        *f = 0;
        return true;
    }
    return false;
}

bool zigit_tray_take_show(ZigitTray *tray) {
    return tray && take_flag(&tray->show);
}
bool zigit_tray_take_quit(ZigitTray *tray) {
    return tray && take_flag(&tray->quit);
}
bool zigit_tray_take_capture_region(ZigitTray *tray) {
    return tray && take_flag(&tray->capture_region);
}
bool zigit_tray_take_capture_window(ZigitTray *tray) {
    return tray && take_flag(&tray->capture_window);
}
