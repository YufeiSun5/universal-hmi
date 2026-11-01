#include "my_application.h"

#include <algorithm>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlEngine* engine;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean trace_window_close(GtkWidget*, GdkEvent*, gpointer) {
  g_printerr("HMI lifecycle: window close requested\n");
  return FALSE;
}

// GDK workareas and GTK allocations are logical application pixels, not
// device pixels. Keep the content useful without forcing a small monitor to
// accommodate an off-screen minimum window.
static int bounded_window_extent(int content, int work_area,
                                 int external_frame, int client_titlebar) {
  return std::max(1, std::min(content + client_titlebar, work_area - external_frame));
}

static void update_window_minimum(GtkWindow* window, bool initial = false) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(window));
  GdkMonitor* monitor = native != nullptr
      ? gdk_display_get_monitor_at_window(display, native)
      : gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor == nullptr) return;

  GdkRectangle work_area;
  gdk_monitor_get_workarea(monitor, &work_area);
  int border_width = 0;
  int border_height = 0;
  if (native != nullptr) {
    // These two measurements describe the same native window. Child widget
    // allocations can lag configure-event and must not be used as a border.
    GdkRectangle frame;
    int native_width = 0;
    int native_height = 0;
    gdk_window_get_geometry(native, nullptr, nullptr, &native_width, &native_height);
    gdk_window_get_frame_extents(native, &frame);
    border_width = std::max(0, frame.width - native_width);
    border_height = std::max(0, frame.height - native_height);
  }
  int internal_width = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "hmi-inner-width"));
  int internal_height = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "hmi-inner-height"));
  if (g_object_get_data(G_OBJECT(window), "hmi-has-allocation") == nullptr) {
    if (GtkWidget* titlebar = gtk_window_get_titlebar(window)) {
      if (gtk_widget_get_visible(titlebar)) {
        gtk_widget_get_preferred_height(titlebar, &internal_height, nullptr);
      }
    }
  }

  // GTK geometry hints include client-side decorations. default_size instead
  // requests content, to which GTK adds those decorations itself.
  if (initial) {
    gtk_window_set_default_size(window,
        bounded_window_extent(1280, work_area.width, border_width + internal_width, 0),
        bounded_window_extent(720, work_area.height, border_height + internal_height, 0));
  }
  const int min_width = bounded_window_extent(900, work_area.width, border_width, internal_width);
  const int min_height = bounded_window_extent(600, work_area.height, border_height, internal_height);
  // configure-event also fires while dragging. Avoid a resize feedback loop
  // by publishing geometry hints only when the effective minimum changes.
  if (GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "hmi-min-width")) == min_width &&
      GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "hmi-min-height")) == min_height) {
    return;
  }
  GdkGeometry geometry = {};
  geometry.min_width = min_width;
  geometry.min_height = min_height;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);
  g_object_set_data(G_OBJECT(window), "hmi-min-width", GINT_TO_POINTER(min_width));
  g_object_set_data(G_OBJECT(window), "hmi-min-height", GINT_TO_POINTER(min_height));
}

// Run after GtkWindow has allocated its child. Both allocations then belong
// to the same layout; never mix a configure event's new size with an old child.
static void window_size_allocated(GtkWidget* widget, GtkAllocation* allocation, gpointer) {
  GtkWidget* child = gtk_bin_get_child(GTK_BIN(widget));
  if (child == nullptr || !gtk_widget_get_mapped(child)) return;
  const int internal_width = std::max(0, allocation->width - gtk_widget_get_allocated_width(child));
  const int internal_height = std::max(0, allocation->height - gtk_widget_get_allocated_height(child));
  g_object_set_data(G_OBJECT(widget), "hmi-inner-width", GINT_TO_POINTER(internal_width));
  g_object_set_data(G_OBJECT(widget), "hmi-inner-height", GINT_TO_POINTER(internal_height));
  g_object_set_data(G_OBJECT(widget), "hmi-has-allocation", GINT_TO_POINTER(1));
  update_window_minimum(GTK_WINDOW(widget));
}

static gboolean window_geometry_changed(GtkWidget* window, GdkEvent*, gpointer) {
  update_window_minimum(GTK_WINDOW(window));
  return FALSE;
}

static void display_geometry_changed(GdkScreen*, GtkWindow* window) {
  update_window_minimum(window);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView *view)
{
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  if (g_getenv("HMI_LIFECYCLE_TRACE") != nullptr) {
    g_signal_connect(window, "delete-event", G_CALLBACK(trace_window_close), nullptr);
  }

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Universal HMI");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Universal HMI");
  }

  gtk_window_set_default_size(window, 1280, 720);
  update_window_minimum(window, true);
  g_signal_connect_after(window, "size-allocate", G_CALLBACK(window_size_allocated), nullptr);
  g_signal_connect(window, "configure-event", G_CALLBACK(window_geometry_changed), nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_geometry_changed), nullptr);
  GdkScreen* window_screen = gtk_window_get_screen(window);
  g_signal_connect_object(window_screen, "monitors-changed",
                          G_CALLBACK(display_geometry_changed), window, static_cast<GConnectFlags>(0));
  g_signal_connect_object(window_screen, "size-changed",
                          G_CALLBACK(display_geometry_changed), window, static_cast<GConnectFlags>(0));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  // Flutter detaches its window from GtkApplication on an approved exit, so
  // retain the engine separately to stop its threads during our shutdown.
  self->engine = FL_ENGINE(g_object_ref(fl_view_get_engine(view)));
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000 for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (g_getenv("HMI_LIFECYCLE_TRACE") != nullptr) {
    g_printerr("HMI lifecycle: application shutdown begin\n");
  }
  // The approved Dart exit has already awaited owned-backend shutdown. Stop
  // rendering before main returns and destroys Skia's process-wide resources.
  // Leave the detached GTK window to process teardown: in Flutter 3.35.4,
  // unrealizing FlView before engine shutdown races the raster GL context;
  // doing it afterwards dereferences the engine's disposed OpenGL manager.
  if (self->engine != nullptr) {
    // The detached view still holds an engine reference. Explicit disposal
    // joins its threads now; merely dropping our reference would not stop it.
    if (g_getenv("HMI_LIFECYCLE_TRACE") != nullptr) {
      g_printerr("HMI lifecycle: engine disposal begin\n");
    }
    g_object_run_dispose(G_OBJECT(self->engine));
    g_clear_object(&self->engine);
    if (g_getenv("HMI_LIFECYCLE_TRACE") != nullptr) {
      g_printerr("HMI lifecycle: engine disposed\n");
    }
  }

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
  if (g_getenv("HMI_LIFECYCLE_TRACE") != nullptr) {
    g_printerr("HMI lifecycle: application shutdown complete\n");
  }
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->engine);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
