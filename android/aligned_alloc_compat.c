/*
 * Link-time aligned_alloc shim for Android API < 28.
 *
 * vcpkg-prebuilt archives (roaring, built against ANDROID_PLATFORM 28 per
 * the release triplets) reference aligned_alloc(), which Bionic only
 * exports from API 28. We target minSdk 24, so provide the symbol via
 * posix_memalign (available since API 16). The duckdb-release-wrapper's
 * aligned_alloc_shim.h handles the same problem at COMPILE time for
 * sources we build ourselves; this file covers symbols baked into
 * prebuilt .a archives, which a -include shim cannot reach.
 */
#include <stdlib.h>

#if defined(__ANDROID__) && defined(__ANDROID_API__) && __ANDROID_API__ < 28
void* aligned_alloc(size_t alignment, size_t size) {
  void* ptr = NULL;
  if (posix_memalign(&ptr, alignment, size) != 0) {
    return NULL;
  }
  return ptr;
}
#endif

#if defined(__ANDROID__) && defined(__ANDROID_API__) && __ANDROID_API__ < 26
#include <sys/socket.h>
/*
 * vcpkg's libcurl.a (built at ANDROID_PLATFORM 28 with _FORTIFY_SOURCE)
 * references __sendto_chk, which Bionic exports only from API 26.
 * Delegate to plain sendto after the same bounds check fortify performs.
 */
ssize_t __sendto_chk(int fd, const void* buf, size_t len, size_t buflen,
                     int flags, const struct sockaddr* dest_addr,
                     socklen_t addrlen) {
  if (len > buflen) {
    abort();
  }
  return sendto(fd, buf, len, flags, dest_addr, addrlen);
}
#endif
