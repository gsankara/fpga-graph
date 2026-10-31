/* Minimal no-op libudev.so.1 shim.
 *
 * Vivado 2023.2's licensing/WebTalk code (libXil_lmgr11.so) dlopens the system
 * libudev and calls udev_enumerate_scan_devices() to build a host fingerprint.
 * On Ubuntu 24.04 (libudev 1.7.8 / glibc 2.39) that path heap-aborts inside
 * realloc() and takes Vivado down -- during the Vitis vpl link, where v++ then
 * never reaps the corpse. Vivado needs nothing from udev for a link, so this
 * shim satisfies every symbol it dlsyms and reports "no devices".
 *
 * Shadowed via LD_LIBRARY_PATH (dlopen resolves to this file, so it works even
 * though the symbols are fetched with dlsym on the handle, which LD_PRELOAD
 * would not intercept).
 */
#include <stddef.h>

struct udev; struct udev_enumerate; struct udev_device; struct udev_list_entry;
static int udev_stub_token;
#define TOK(T) ((struct T *)&udev_stub_token)

struct udev *udev_new(void) { return TOK(udev); }
struct udev *udev_unref(struct udev *u) { (void)u; return NULL; }
struct udev *udev_ref(struct udev *u) { return u; }

struct udev_enumerate *udev_enumerate_new(struct udev *u) { (void)u; return TOK(udev_enumerate); }
struct udev_enumerate *udev_enumerate_unref(struct udev_enumerate *e) { (void)e; return NULL; }
int udev_enumerate_scan_devices(struct udev_enumerate *e) { (void)e; return 0; }
int udev_enumerate_add_match_subsystem(struct udev_enumerate *e, const char *s) { (void)e; (void)s; return 0; }
struct udev_list_entry *udev_enumerate_get_list_entry(struct udev_enumerate *e) { (void)e; return NULL; }

struct udev_list_entry *udev_list_entry_get_next(struct udev_list_entry *l) { (void)l; return NULL; }
const char *udev_list_entry_get_name(struct udev_list_entry *l) { (void)l; return NULL; }
const char *udev_list_entry_get_value(struct udev_list_entry *l) { (void)l; return NULL; }

struct udev_device *udev_device_new_from_syspath(struct udev *u, const char *p) { (void)u; (void)p; return NULL; }
struct udev_device *udev_device_unref(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_devnode(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_devpath(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_devtype(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_subsystem(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_sysname(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_sysnum(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_syspath(struct udev_device *d) { (void)d; return NULL; }
struct udev_list_entry *udev_device_get_devlinks_list_entry(struct udev_device *d) { (void)d; return NULL; }
struct udev_list_entry *udev_device_get_properties_list_entry(struct udev_device *d) { (void)d; return NULL; }
