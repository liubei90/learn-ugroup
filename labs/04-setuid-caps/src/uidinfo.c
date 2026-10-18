/* labs/04-setuid-caps/src/uidinfo.c
 * 打印 real/effective/saved uid 与 gid，并尝试读取一个文件（默认 /root/secret.txt）。
 * 用途：观察 SUID 程序执行后 euid/suid 的变化。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    uid_t ruid, euid, suid;
    gid_t rgid, egid, sgid;

    if (getresuid(&ruid, &euid, &suid) != 0) {
        perror("getresuid");
        return 1;
    }
    if (getresgid(&rgid, &egid, &sgid) != 0) {
        perror("getresgid");
        return 1;
    }
    printf("real=%u effective=%u saved=%u | gid real=%u eff=%u saved=%u\n",
           (unsigned)ruid, (unsigned)euid, (unsigned)suid,
           (unsigned)rgid, (unsigned)egid, (unsigned)sgid);

    const char *path = (argc > 1) ? argv[1] : "/root/secret.txt";
    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        printf("read %s: DENIED (euid=%u)\n", path, (unsigned)euid);
        return 0;
    }
    char buf[128];
    if (fgets(buf, sizeof buf, fp) != NULL) {
        buf[strcspn(buf, "\r\n")] = '\0';
        printf("read %s: OK -> %s\n", path, buf);
    } else {
        printf("read %s: OK (empty)\n", path);
    }
    fclose(fp);
    return 0;
}
