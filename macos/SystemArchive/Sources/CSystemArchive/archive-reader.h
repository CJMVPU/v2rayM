// Swift bindings for the system libarchive used by the app and build tools.
// Swift supplies all entry paths and streams file contents through these opaque handles.
#include <stdint.h>
#include <sys/types.h>
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_free(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_open_fd(struct archive *, int);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, unsigned int);
