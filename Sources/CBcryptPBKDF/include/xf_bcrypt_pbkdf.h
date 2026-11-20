#ifndef XF_BCRYPT_PBKDF_H
#define XF_BCRYPT_PBKDF_H
#include <stddef.h>
#include <stdint.h>

/// OpenBSD bcrypt_pbkdf (used by OpenSSH "new format" encrypted private keys).
/// Returns 0 on success, -1 on invalid arguments.
int xf_bcrypt_pbkdf(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                    uint8_t *key, size_t keylen, unsigned int rounds);
#endif
