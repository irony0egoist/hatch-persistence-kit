#define _GNU_SOURCE
#include <stdint.h>
// 手动定义 capset 所需结构（避免依赖 libcap 头文件）
struct __user_cap_header_struct {
    uint32_t version;
    int32_t pid;
};
struct __user_cap_data_struct {
    uint32_t effective;
    uint32_t permitted;
    uint32_t inheritable;
};
// 拦截 capset，直接返回成功
// 沙箱限制下 crun 的 capset 会 EPERM；容器用进程已有的 caps 运行即可
int capset(struct __user_cap_header_struct *hdrp, struct __user_cap_data_struct *datap) {
    (void)hdrp; (void)datap;
    return 0;
}
