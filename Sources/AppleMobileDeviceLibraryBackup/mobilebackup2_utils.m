//
//  mobilebackup2_utils.c.c
//
//
//  Created by QAQ on 2023/8/15.
//

#include "mobilebackup2_utils.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/mobilebackup.h>
#include <libimobiledevice/notification_proxy.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice-glue/utils.h>

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <getopt.h>
#include <libgen.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#include "Endianness.h"

#define CODE_SUCCESS 0x00
#define CODE_ERROR_LOCAL 0x06
#define CODE_ERROR_REMOTE 0x0b
#define CODE_FILE_DATA 0x0c

int nop_printf(const char *whatever, ...) { }

int remove_file(const char *path) {
    return remove(path) < 0 ? errno : 0;
}

static int remove_directory(const char* path)
{
    return remove(path) < 0 ? errno : 0;
}

struct entry_b {
    char *name;
    struct entry_b *next;
};

static void scan_directory(const char *path, struct entry_b **files, struct entry_b **directories)
{
    DIR* cur_dir = opendir(path);
    if (cur_dir) {
        struct dirent* ep;
        while ((ep = readdir(cur_dir))) {
            if ((strcmp(ep->d_name, ".") == 0) || (strcmp(ep->d_name, "..") == 0)) {
                continue;
            }
            char *fpath = string_build_path(path, ep->d_name, NULL);
            if (fpath) {
                struct stat st;
                if (stat(fpath, &st) != 0) return;
                if (S_ISDIR(st.st_mode)) {
                    struct entry_b *ent = malloc(sizeof(struct entry_b));
                    if (!ent) return;
                    ent->name = fpath;
                    ent->next = *directories;
                    *directories = ent;
                    scan_directory(fpath, files, directories);
                    fpath = NULL;
                } else {
                    struct entry_b *ent = malloc(sizeof(struct entry_b));
                    if (!ent) return;
                    ent->name = fpath;
                    ent->next = *files;
                    *files = ent;
                    fpath = NULL;
                }
            }
        }
        closedir(cur_dir);
    }
}
static int rmdir_recursive(const char* path)
{
    int res = 0;
    struct entry_b *files = NULL;
    struct entry_b *directories = NULL;
    struct entry_b *ent;
    
    ent = malloc(sizeof(struct entry_b));
    if (!ent) return ENOMEM;
    ent->name = strdup(path);
    ent->next = NULL;
    directories = ent;
    
    scan_directory(path, &files, &directories);
    
    ent = files;
    while (ent) {
        struct entry_b *del = ent;
        res = remove_file(ent->name);
        free(ent->name);
        ent = ent->next;
        free(del);
    }
    ent = directories;
    while (ent) {
        struct entry_b *del = ent;
        res = remove_directory(ent->name);
        free(ent->name);
        ent = ent->next;
        free(del);
    }
    
    return res;
}

int mkdir_with_parents(const char *dir, int mode) {
    if (!dir)
        return -1;
    if (mkdir(dir, mode) == 0) {
        return 0;
    }
    if (errno == EEXIST)
        return 0;
    int res;
    char *parent = strdup(dir);
    char *parentdir = dirname(parent);
    if (parentdir) {
        res = mkdir_with_parents(parentdir, mode);
    } else {
        res = -1;
    }
    free(parent);
    if (res == 0) {
        mkdir_with_parents(dir, mode);
    }
    return res;
}

static void mb2_copy_file_by_path(const char *src, const char *dst)
{
    FILE *from, *to;
    char buf[BUFSIZ];
    size_t length;
    
    /* open source file */
    if ((from = fopen(src, "rb")) == NULL) {
        nop_printf("Cannot open source path '%s'.\n", src);
        return;
    }
    
    /* open destination file */
    if ((to = fopen(dst, "wb")) == NULL) {
        nop_printf("Cannot open destination file '%s'.\n", dst);
        fclose(from);
        return;
    }
    
    /* copy the file */
    while ((length = fread(buf, 1, BUFSIZ, from)) != 0) {
        fwrite(buf, 1, length, to);
    }
    
    if(fclose(from) == EOF) {
        nop_printf("Error closing source file.\n");
    }
    
    if(fclose(to) == EOF) {
        nop_printf("Error closing destination file.\n");
    }
}

static void mb2_copy_directory_by_path(const char *src, const char *dst)
{
    if (!src || !dst) {
        return;
    }
    
    struct stat st;
    
    /* if src does not exist */
    if ((stat(src, &st) < 0) || !S_ISDIR(st.st_mode)) {
        nop_printf("ERROR: Source directory does not exist '%s': %s (%d)\n", src, strerror(errno), errno);
        return;
    }
    
    /* if dst directory does not exist */
    if ((stat(dst, &st) < 0) || !S_ISDIR(st.st_mode)) {
        /* create it */
        if (mkdir_with_parents(dst, 0755) < 0) {
            nop_printf("ERROR: Unable to create destination directory '%s': %s (%d)\n", dst, strerror(errno), errno);
            return;
        }
    }
    
    /* loop over src directory contents */
    DIR *cur_dir = opendir(src);
    if (cur_dir) {
        struct dirent* ep;
        while ((ep = readdir(cur_dir))) {
            if ((strcmp(ep->d_name, ".") == 0) || (strcmp(ep->d_name, "..") == 0)) {
                continue;
            }
            char *srcpath = string_build_path(src, ep->d_name, NULL);
            char *dstpath = string_build_path(dst, ep->d_name, NULL);
            if (srcpath && dstpath) {
                /* copy file */
                mb2_copy_file_by_path(srcpath, dstpath);
            }
            
            if (srcpath)
                free(srcpath);
            if (dstpath)
                free(dstpath);
        }
        closedir(cur_dir);
    }
}


int errno_to_device_error(int errno_value) {
    switch (errno_value) {
        case ENOENT:
            return -6;
        case EEXIST:
            return -7;
        case ENOTDIR:
            return -8;
        case EISDIR:
            return -9;
        case ELOOP:
            return -10;
        case EIO:
            return -11;
        case ENOSPC:
            return -15;
        default:
            return -1;
    }
}

void mb2_multi_status_add_file_error(plist_t status_dict,
                                     const char *path, int error_code,
                                     const char *error_message) {
    if (!status_dict)
        return;
    plist_t filedict = plist_new_dict();
    plist_dict_set_item(filedict, "DLFileErrorString",
                        plist_new_string(error_message));
    plist_dict_set_item(filedict, "DLFileErrorCode", plist_new_uint(error_code));
    plist_dict_set_item(status_dict, path, filedict);
}

int mb2_handle_send_file(mobilebackup2_client_t mobilebackup2,
                         const char *backup_dir, const char *path,
                         plist_t *errplist) {
    uint32_t nlen = 0;
    uint32_t pathlen = (uint32_t)strlen(path);
    uint32_t bytes = 0;
    char *localfile = string_build_path(backup_dir, path, NULL);
    char buf[32768];
    struct stat fst;
    
    FILE *f = NULL;
    uint32_t slen = 0;
    int errcode = -1;
    int result = -1;
    uint32_t length;
    off_t total;
    off_t sent;
    
    mobilebackup2_error_t err;
    
    /* send path length */
    nlen = htobe32(pathlen);
    err = mobilebackup2_send_raw(mobilebackup2, (const char *)&nlen, sizeof(nlen),
                                 &bytes);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        goto leave_proto_err;
    }
    if (bytes != (uint32_t)sizeof(nlen)) {
        err = MOBILEBACKUP2_E_MUX_ERROR;
        goto leave_proto_err;
    }
    
    /* send path */
    err = mobilebackup2_send_raw(mobilebackup2, path, pathlen, &bytes);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        goto leave_proto_err;
    }
    if (bytes != pathlen) {
        err = MOBILEBACKUP2_E_MUX_ERROR;
        goto leave_proto_err;
    }
    
    if (stat(localfile, &fst) < 0) {
        if (errno != ENOENT)
            nop_printf("%s: stat failed on '%s': %d\n", __func__, localfile, errno);
        errcode = errno;
        goto leave;
    }
    
    total = fst.st_size;
    
    char *format_size = string_format_size(total);
    free(format_size);
    
    if (total == 0) {
        errcode = 0;
        goto leave;
    }
    
    f = fopen(localfile, "rb");
    if (!f) {
        errcode = errno;
        goto leave;
    }
    
    sent = 0;
    do {
        length = ((total - sent) < (long long)sizeof(buf))
        ? (uint32_t)total - (uint32_t)sent
        : (uint32_t)sizeof(buf);
        /* send data size (file size + 1) */
        nlen = htobe32(length + 1);
        memcpy(buf, &nlen, sizeof(nlen));
        buf[4] = CODE_FILE_DATA;
        err = mobilebackup2_send_raw(mobilebackup2, (const char *)buf, 5, &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS) {
            goto leave_proto_err;
        }
        if (bytes != 5) {
            goto leave_proto_err;
        }
        
        /* send file contents */
        size_t r = fread(buf, 1, sizeof(buf), f);
        if (r <= 0) {
            nop_printf("%s: read error\n", __func__);
            errcode = errno;
            goto leave;
        }
        err = mobilebackup2_send_raw(mobilebackup2, buf, (uint32_t)r, &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS) {
            goto leave_proto_err;
        }
        if (bytes != (uint32_t)r) {
            nop_printf("Error: sent only %d of %d bytes\n", bytes, (int)r);
            goto leave_proto_err;
        }
        sent += r;
    } while (sent < total);
    fclose(f);
    f = NULL;
    errcode = 0;
    
leave:
    if (errcode == 0) {
        result = 0;
        nlen = 1;
        nlen = htobe32(nlen);
        memcpy(buf, &nlen, 4);
        buf[4] = CODE_SUCCESS;
        mobilebackup2_send_raw(mobilebackup2, buf, 5, &bytes);
    } else {
        if (!*errplist) {
            *errplist = plist_new_dict();
        }
        char *errdesc = strerror(errcode);
        mb2_multi_status_add_file_error(*errplist, path,
                                        errno_to_device_error(errcode), errdesc);
        
        length = (uint32_t)strlen(errdesc);
        nlen = htobe32(length + 1);
        memcpy(buf, &nlen, 4);
        buf[4] = CODE_ERROR_LOCAL;
        slen = 5;
        memcpy(buf + slen, errdesc, length);
        slen += length;
        err =
        mobilebackup2_send_raw(mobilebackup2, (const char *)buf, slen, &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS) {
            nop_printf("could not send message\n");
        }
        if (bytes != slen) {
            nop_printf("could only send %d from %d\n", bytes, slen);
        }
    }
    
leave_proto_err:
    if (f)
        fclose(f);
    free(localfile);
    return result;
}

void mb2_handle_send_files(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_dir) {
    uint32_t cnt;
    uint32_t i = 0;
    uint32_t sent;
    plist_t errplist = NULL;
    
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) ||
        (plist_array_get_size(message) < 2) || !backup_dir)
        return;
    
    plist_t files = plist_array_get_item(message, 1);
    cnt = plist_array_get_size(files);
    
    for (i = 0; i < cnt; i++) {
        plist_t val = plist_array_get_item(files, i);
        if (plist_get_node_type(val) != PLIST_STRING) {
            continue;
        }
        char *str = NULL;
        plist_get_string_val(val, &str);
        if (!str)
            continue;
        
        if (mb2_handle_send_file(mobilebackup2, backup_dir, str, &errplist) < 0) {
            free(str);
            // nop_printf("Error when sending file '%s' to device\n", str);
            //  TODO: perhaps we can continue, we've got a multi status response?!
            break;
        }
        free(str);
    }
    
    /* send terminating 0 dword */
    uint32_t zero = 0;
    mobilebackup2_send_raw(mobilebackup2, (char *)&zero, 4, &sent);
    
    if (!errplist) {
        plist_t emptydict = plist_new_dict();
        mobilebackup2_send_status_response(mobilebackup2, 0, NULL, emptydict);
        plist_free(emptydict);
    } else {
        mobilebackup2_send_status_response(mobilebackup2, -13, "Multi status",
                                           errplist);
        plist_free(errplist);
    }
}

int mb2_receive_filename(mobilebackup2_client_t mobilebackup2,
                         char **filename) {
    uint32_t nlen = 0;
    uint32_t rlen = 0;
    
    do {
        nlen = 0;
        rlen = 0;
        mobilebackup2_receive_raw(mobilebackup2, (char *)&nlen, 4, &rlen);
        nlen = be32toh(nlen);
        
        if ((nlen == 0) && (rlen == 4)) {
            // a zero length means no more files to receive
            return 0;
        }
        if (rlen == 0) {
            // device needs more time, waiting...
            continue;
        }
        if (nlen > 4096) {
            // filename length is too large
            return 0;
        }
        
        if (*filename != NULL) {
            free(*filename);
            *filename = NULL;
        }
        
        *filename = (char *)malloc(nlen + 1);
        
        rlen = 0;
        mobilebackup2_receive_raw(mobilebackup2, *filename, nlen, &rlen);
        if (rlen != nlen) {
            return 0;
        }
        
        char *p = *filename;
        p[rlen] = 0;
        
        break;
    } while (1);
    
    return nlen;
}

int mb2_handle_receive_files(mobilebackup2_client_t mobilebackup2,
                             plist_t message, const char *backup_dir) {
    uint64_t backup_real_size = 0;
    uint64_t backup_total_size = 0;
    uint32_t blocksize;
    uint32_t bdone;
    uint32_t rlen;
    uint32_t nlen = 0;
    uint32_t r;
    char buf[32768];
    char *fname = NULL;
    char *dname = NULL;
    char *bname = NULL;
    char code = 0;
    char last_code = 0;
    plist_t node = NULL;
    FILE *f = NULL;
    unsigned int file_count = 0;
    int errcode = 0;
    char *errdesc = NULL;
    
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) ||
        plist_array_get_size(message) < 4 || !backup_dir)
        return 0;
    
    node = plist_array_get_item(message, 3);
    if (plist_get_node_type(node) == PLIST_UINT) {
        plist_get_uint_val(node, &backup_total_size);
    }
    
    do {
        nlen = mb2_receive_filename(mobilebackup2, &dname);
        if (nlen == 0) {
            break;
        }
        
        nlen = mb2_receive_filename(mobilebackup2, &fname);
        if (!nlen) {
            break;
        }
        
        if (bname != NULL) {
            free(bname);
            bname = NULL;
        }
        
        bname = string_build_path(backup_dir, fname, NULL);
        
        if (fname != NULL) {
            free(fname);
            fname = NULL;
        }
        
        r = 0;
        nlen = 0;
        mobilebackup2_receive_raw(mobilebackup2, (char *)&nlen, 4, &r);
        if (r != 4) {
            break;
        }
        nlen = be32toh(nlen);
        
        last_code = code;
        code = 0;
        
        mobilebackup2_receive_raw(mobilebackup2, &code, 1, &r);
        if (r != 1) {
            break;
        }
        
        remove_file(bname);
        f = fopen(bname, "wb");
        while (f && (code == CODE_FILE_DATA)) {
            blocksize = nlen - 1;
            bdone = 0;
            rlen = 0;
            while (bdone < blocksize) {
                if ((blocksize - bdone) < sizeof(buf)) {
                    rlen = blocksize - bdone;
                } else {
                    rlen = sizeof(buf);
                }
                mobilebackup2_receive_raw(mobilebackup2, buf, rlen, &r);
                if ((int)r <= 0) {
                    break;
                }
                fwrite(buf, 1, r, f);
                bdone += r;
            }
            if (bdone == blocksize) {
                backup_real_size += blocksize;
            }
            nlen = 0;
            mobilebackup2_receive_raw(mobilebackup2, (char *)&nlen, 4, &r);
            nlen = be32toh(nlen);
            if (nlen > 0) {
                last_code = code;
                mobilebackup2_receive_raw(mobilebackup2, &code, 1, &r);
            } else {
                break;
            }
        }
        if (f) {
            fclose(f);
            file_count++;
        } else {
            errcode = errno_to_device_error(errno);
            errdesc = strerror(errno);
            nop_printf("Error opening '%s' for writing: %s\n", bname, errdesc);
            break;
        }
        if (nlen == 0) {
            break;
        }
        
        /* check if an error message was received */
        if (code == CODE_ERROR_REMOTE) {
            /* error message */
            char *msg = (char *)malloc(nlen);
            mobilebackup2_receive_raw(mobilebackup2, msg, nlen - 1, &r);
            msg[r] = 0;
            /* If sent using CODE_FILE_DATA, end marker will be CODE_ERROR_REMOTE
             * which is not an error! */
            if (last_code != CODE_FILE_DATA) {
                nop_printf("\nReceived an error message from device: %s\n", msg);
            }
            free(msg);
        }
    } while (1);
    
    if (fname != NULL)
        free(fname);
    
    /* if there are leftovers to read, finish up cleanly */
    if ((int)nlen - 1 > 0) {
        fname = (char *)malloc(nlen - 1);
        mobilebackup2_receive_raw(mobilebackup2, fname, nlen - 1, &r);
        free(fname);
        remove_file(bname);
    }
    
    /* clean up */
    if (bname != NULL)
        free(bname);
    
    if (dname != NULL)
        free(dname);
    
    plist_t empty_plist = plist_new_dict();
    mobilebackup2_send_status_response(mobilebackup2, errcode, errdesc,
                                       empty_plist);
    plist_free(empty_plist);
    
    return file_count;
}

void mb2_handle_list_directory(mobilebackup2_client_t mobilebackup2,
                               plist_t message, const char *backup_dir) {
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) ||
        plist_array_get_size(message) < 2 || !backup_dir)
        return;
    
    plist_t node = plist_array_get_item(message, 1);
    char *str = NULL;
    if (plist_get_node_type(node) == PLIST_STRING) {
        plist_get_string_val(node, &str);
    }
    if (!str) {
        nop_printf("ERROR: Malformed DLContentsOfDirectory message\n");
        // TODO error handling
        return;
    }
    
    char *path = string_build_path(backup_dir, str, NULL);
    free(str);
    
    plist_t dirlist = plist_new_dict();
    
    DIR *cur_dir = opendir(path);
    if (cur_dir) {
        struct dirent *ep;
        while ((ep = readdir(cur_dir))) {
            if ((strcmp(ep->d_name, ".") == 0) || (strcmp(ep->d_name, "..") == 0)) {
                continue;
            }
            char *fpath = string_build_path(path, ep->d_name, NULL);
            if (fpath) {
                plist_t fdict = plist_new_dict();
                struct stat st;
                stat(fpath, &st);
                const char *ftype = "DLFileTypeUnknown";
                if (S_ISDIR(st.st_mode)) {
                    ftype = "DLFileTypeDirectory";
                } else if (S_ISREG(st.st_mode)) {
                    ftype = "DLFileTypeRegular";
                }
                plist_dict_set_item(fdict, "DLFileType", plist_new_string(ftype));
                plist_dict_set_item(fdict, "DLFileSize", plist_new_uint(st.st_size));
                plist_dict_set_item(fdict, "DLFileModificationDate",
                                    plist_new_date((int32_t)st.st_mtime - MAC_EPOCH, 0));
                
                plist_dict_set_item(dirlist, ep->d_name, fdict);
                free(fpath);
            }
        }
        closedir(cur_dir);
    }
    free(path);
    
    /* TODO error handling */
    mobilebackup2_error_t err =
    mobilebackup2_send_status_response(mobilebackup2, 0, NULL, dirlist);
    plist_free(dirlist);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        nop_printf("Could not send status response, error %d\n", err);
    }
}

void mb2_handle_make_directory(mobilebackup2_client_t mobilebackup2,
                               plist_t message, const char *backup_dir) {
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) ||
        plist_array_get_size(message) < 2 || !backup_dir)
        return;
    
    plist_t dir = plist_array_get_item(message, 1);
    char *str = NULL;
    int errcode = 0;
    char *errdesc = NULL;
    plist_get_string_val(dir, &str);
    
    char *newpath = string_build_path(backup_dir, str, NULL);
    free(str);
    
    if (mkdir_with_parents(newpath, 0755) < 0) {
        errdesc = strerror(errno);
        if (errno != EEXIST) {
            nop_printf("mkdir: %s (%d)\n", errdesc, errno);
        }
        errcode = errno_to_device_error(errno);
    }
    free(newpath);
    mobilebackup2_error_t err =
    mobilebackup2_send_status_response(mobilebackup2, errcode, errdesc, NULL);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        nop_printf("Could not send status response, error %d\n", err);
    }
}

void mb2_handle_free_space(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory) {
    uint64_t freespace = 0;
    int res = -1;
    struct statvfs fs;
    memset(&fs, '\0', sizeof(fs));
    res = statvfs(backup_directory, &fs);
    if (res == 0) {
        freespace = (uint64_t)fs.f_bavail * (uint64_t)fs.f_bsize;
    }
    plist_t freespace_item = plist_new_uint(freespace);
    mobilebackup2_send_status_response(mobilebackup2, res, NULL, freespace_item);
    plist_free(freespace_item);
}

void mb2_handle_move_items(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory) {
    plist_t moves = plist_array_get_item(message, 1);
    uint32_t cnt = plist_dict_get_size(moves);
    plist_dict_iter iter = NULL;
    plist_dict_new_iter(moves, &iter);
    int errcode = 0;
    const char *errdesc = NULL;
    struct stat st;
    if (iter) {
        char *key = NULL;
        plist_t val = NULL;
        do {
            plist_dict_next_item(moves, iter, &key, &val);
            if (key && (plist_get_node_type(val) == PLIST_STRING)) {
                char *str = NULL;
                plist_get_string_val(val, &str);
                if (str) {
                    char *newpath = string_build_path(backup_directory, str, NULL);
                    free(str);
                    char *oldpath = string_build_path(backup_directory, key, NULL);
                    
                    if ((stat(newpath, &st) == 0) && S_ISDIR(st.st_mode))
                        rmdir_recursive(newpath);
                    else
                        remove_file(newpath);
                    if (rename(oldpath, newpath) < 0) {
                        nop_printf("Renameing '%s' to '%s' failed: %s (%d)\n", oldpath, newpath, strerror(errno), errno);
                        errcode = errno_to_device_error(errno);
                        errdesc = strerror(errno);
                        break;
                    }
                    free(oldpath);
                    free(newpath);
                }
                free(key);
                key = NULL;
            }
        } while (val);
        free(iter);
    } else {
        errcode = -1;
        errdesc = "Could not create dict iterator";
        nop_printf("Could not create dict iterator\n");
    }
    plist_t empty_dict = plist_new_dict();
    int err = mobilebackup2_send_status_response(mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        nop_printf("Could not send status response, error %d\n", err);
    }
}

void mb2_handle_remove_items(mobilebackup2_client_t mobilebackup2,
                             plist_t message, const char *backup_directory) {
    plist_t removes = plist_array_get_item(message, 1);
    uint32_t cnt = plist_array_get_size(removes);
    uint32_t ii = 0;
    int errcode = 0;
    const char *errdesc = NULL;
    struct stat st;
    for (ii = 0; ii < cnt; ii++) {
        plist_t val = plist_array_get_item(removes, ii);
        if (plist_get_node_type(val) == PLIST_STRING) {
            char *str = NULL;
            plist_get_string_val(val, &str);
            if (str) {
                const char *checkfile = strchr(str, '/');
                int suppress_warning = 0;
                if (checkfile) {
                    if (strcmp(checkfile+1, "Manifest.mbdx") == 0) {
                        suppress_warning = 1;
                    }
                }
                char *newpath = string_build_path(backup_directory, str, NULL);
                free(str);
                int res = 0;
                if ((stat(newpath, &st) == 0) && S_ISDIR(st.st_mode)) {
                    res = rmdir_recursive(newpath);
                } else {
                    res = remove_file(newpath);
                }
                if (res != 0 && res != ENOENT) {
                    if (!suppress_warning)
                        nop_printf("Could not remove '%s': %s (%d)\n", newpath, strerror(res), res);
                    errcode = errno_to_device_error(res);
                    errdesc = strerror(res);
                }
                free(newpath);
            }
        }
    }
    plist_t empty_dict = plist_new_dict();
    int err = mobilebackup2_send_status_response(mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        nop_printf("Could not send status response, error %d\n", err);
    }
}

void mb2_handle_copy_items(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory) {
    plist_t srcpath = plist_array_get_item(message, 1);
    plist_t dstpath = plist_array_get_item(message, 2);
    int errcode = 0;
    const char *errdesc = NULL;
    struct stat st;
    if ((plist_get_node_type(srcpath) == PLIST_STRING) && (plist_get_node_type(dstpath) == PLIST_STRING)) {
        char *src = NULL;
        char *dst = NULL;
        plist_get_string_val(srcpath, &src);
        plist_get_string_val(dstpath, &dst);
        if (src && dst) {
            char *oldpath = string_build_path(backup_directory, src, NULL);
            char *newpath = string_build_path(backup_directory, dst, NULL);
            /* check that src exists */
            if ((stat(oldpath, &st) == 0) && S_ISDIR(st.st_mode)) {
                mb2_copy_directory_by_path(oldpath, newpath);
            } else if ((stat(oldpath, &st) == 0) && S_ISREG(st.st_mode)) {
                mb2_copy_file_by_path(oldpath, newpath);
            }
            
            free(newpath);
            free(oldpath);
        }
        free(src);
        free(dst);
    }
    plist_t empty_dict = plist_new_dict();
    int err = mobilebackup2_send_status_response(mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        nop_printf("Could not send status response, error %d\n", err);
    }
}
