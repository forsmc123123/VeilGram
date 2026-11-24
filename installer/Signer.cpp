#include "Signer.h"
#include "archive.h"
#include "bundle.h"
#include "third-party/minizip/unzip.h"
#include <openssl/cms.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>

int VGUnpackIPA(const char *ipa, const char *destination) {
    auto zip = unzOpen64(ipa);
    if (!zip) return 0;
    unz_global_info64 index{};
    uint64_t unpacked = 0;
    constexpr uint64_t maxSize = 4ULL << 30;
    bool valid = unzGetGlobalInfo64(zip, &index) == UNZ_OK
        && index.number_entry > 0 && index.number_entry <= 100000;
    for (uint64_t i = 0; valid && i < index.number_entry; ++i) {
        char name[PATH_MAX]{};
        unz_file_info64 item{};
        if (unzGetCurrentFileInfo64(zip, &item, name, sizeof(name), nullptr, 0, nullptr, 0) != UNZ_OK
            || item.size_filename >= sizeof(name) || item.size_filename != strlen(name)
            || item.uncompressed_size > maxSize - unpacked || (item.flag & 1)) {
            valid = false;
            break;
        }
        unpacked += item.uncompressed_size;
        string path(name);
        valid = path == "Payload/" || path.compare(0, 21, "Payload/Telegram.app/") == 0
            || path.compare(0, 13, "SwiftSupport/") == 0 || path.compare(0, 8, "Symbols/") == 0;
        valid = valid && path.find_first_of("\\:\r\n") == string::npos
            && (path + "/").find("/../") == string::npos && (path + "/").find("/./") == string::npos
            && ((item.external_fa >> 16) & S_IFMT) != S_IFLNK;
        if (valid && i + 1 < index.number_entry) valid = unzGoToNextFile(zip) == UNZ_OK;
    }
    unzClose(zip);
    return valid && Zip::Extract(ipa, destination);
}

int VGPackIPA(const char *payload, const char *ipa) {
    return Zip::Archive(payload, ipa, 0);
}

static CMS_ContentInfo *readProfile(const char *path) {
    auto input = BIO_new_file(path, "rb");
    if (!input) return nullptr;
    auto cms = d2i_CMS_bio(input, nullptr);
    BIO_free(input);
    return cms;
}

void *VGCopyProfile(const char *path, size_t *length) {
    *length = 0;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(readProfile(path), CMS_ContentInfo_free);
    if (!cms) return nullptr;
    auto content = CMS_get0_content(cms.get());
    if (!content || !*content) return nullptr;
    auto size = ASN1_STRING_length(*content);
    if (size <= 0) return nullptr;
    auto result = malloc(static_cast<size_t>(size));
    if (!result) return nullptr;
    memcpy(result, ASN1_STRING_get0_data(*content), static_cast<size_t>(size));
    *length = static_cast<size_t>(size);
    return result;
}

void VGFree(void *buffer) { free(buffer); }

int VGSignApp(const char *app, const char *p12, const char *profile, const char *entitlements,
              const char *password, const char *bundleID) {
    size_t size = 0;
    std::unique_ptr<void, decltype(&VGFree)> data(VGCopyProfile(profile, &size), VGFree);
    jvalue provision;
    if (!data || !provision.read_plist(string(static_cast<const char *>(data.get()), size))) return 1;

    auto input = BIO_new_file(p12, "rb");
    if (!input) return 1;
    std::unique_ptr<PKCS12, decltype(&PKCS12_free)> identity(d2i_PKCS12_bio(input, nullptr), PKCS12_free);
    BIO_free(input);
    static auto standard = OSSL_PROVIDER_load(nullptr, "default");
    static auto legacy = OSSL_PROVIDER_load(nullptr, "legacy");
    (void)standard;
    (void)legacy;
    EVP_PKEY *key = nullptr;
    X509 *leaf = nullptr;
    const bool parsed = identity && PKCS12_parse(identity.get(), password, &key, &leaf, nullptr);
    auto certificate = std::unique_ptr<X509, decltype(&X509_free)>(leaf, X509_free);
    EVP_PKEY_free(key);
    if (!parsed || !certificate) return 1;
    if (X509_cmp_current_time(X509_get0_notBefore(leaf)) >= 0
        || X509_cmp_current_time(X509_get0_notAfter(leaf)) <= 0) return 3;
    unsigned char *der = nullptr;
    const int length = i2d_X509(leaf, &der);
    string bytes;
    if (length > 0) bytes.assign(reinterpret_cast<const char *>(der), length);
    OPENSSL_free(der);
    if (bytes.empty()) return 1;
    const auto &certificates = provision["DeveloperCertificates"];
    bool matches = false;
    for (size_t i = 0; i < certificates.size(); ++i) {
        if (certificates[i].as_data() == bytes) {
            matches = true;
            break;
        }
    }
    if (!matches) return 3;

    ZSignAsset asset;
    if (!asset.Init("", p12, profile, entitlements, password, false, false, false)) return 1;
    ZBundle bundle;
    // Signing is confined to the caller's extracted copy, and no cache or dylib injection is used.
    return bundle.SignFolder(&asset, app, bundleID, "", "", {}, {}, true, false, false) ? 0 : 2;
}
