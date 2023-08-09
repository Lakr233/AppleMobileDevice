//
//  mobilebackup2_utils.c.h
//  
//
//  Created by QAQ on 2023/8/15.
//

#ifndef mobilebackup2_utils_c_h
#define mobilebackup2_utils_c_h

//@import AppleMobileDeviceLibrary;
#include <libimobiledevice/libimobiledevice.h>

void mb2_multi_status_add_file_error(plist_t status_dict,
                                     const char *path, int error_code,
                                     const char *error_message);

int mb2_handle_send_file(mobilebackup2_client_t mobilebackup2,
                         const char *backup_dir, const char *path,
                         plist_t *errplist);

void mb2_handle_send_files(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_dir);

int mb2_receive_filename(mobilebackup2_client_t mobilebackup2,
                         char **filename);

int mb2_handle_receive_files(mobilebackup2_client_t mobilebackup2,
                             plist_t message, const char *backup_dir);

void mb2_handle_list_directory(mobilebackup2_client_t mobilebackup2,
                               plist_t message, const char *backup_dir);

void mb2_handle_make_directory(mobilebackup2_client_t mobilebackup2,
                               plist_t message, const char *backup_dir);

void mb2_handle_free_space(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory);

void mb2_handle_move_items(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory);

void mb2_handle_remove_items(mobilebackup2_client_t mobilebackup2,
                             plist_t message, const char *backup_directory);

void mb2_handle_copy_items(mobilebackup2_client_t mobilebackup2,
                           plist_t message, const char *backup_directory);

#endif /* mobilebackup2_utils_c_h */
