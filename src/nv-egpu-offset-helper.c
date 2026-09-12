#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

typedef int (*nvml_init_t)(void);
typedef int (*nvml_shutdown_t)(void);
typedef int (*nvml_device_get_handle_by_index_t)(unsigned int, void **);
typedef int (*nvml_device_set_gpc_clk_vf_offset_t)(void *, int);
typedef int (*nvml_device_set_mem_clk_vf_offset_t)(void *, int);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <gpc_offset_mhz> [mem_offset_mhz]\n", argv[0]);
        return 1;
    }
    int gpc_offset = atoi(argv[1]);
    int mem_offset = (argc >= 3) ? atoi(argv[2]) : 0;

    void *lib = dlopen("libnvidia-ml.so.1", RTLD_LAZY);
    if (!lib) {
        lib = dlopen("libnvidia-ml.so", RTLD_LAZY);
    }
    if (!lib) {
        fprintf(stderr, "Failed to load libnvidia-ml.so: %s\n", dlerror());
        return 2;
    }

    nvml_init_t nvmlInit = (nvml_init_t)dlsym(lib, "nvmlInit_v2");
    if (!nvmlInit) nvmlInit = (nvml_init_t)dlsym(lib, "nvmlInit");
    
    nvml_shutdown_t nvmlShutdown = (nvml_shutdown_t)dlsym(lib, "nvmlShutdown");
    nvml_device_get_handle_by_index_t nvmlDeviceGetHandleByIndex = 
        (nvml_device_get_handle_by_index_t)dlsym(lib, "nvmlDeviceGetHandleByIndex_v2");
    if (!nvmlDeviceGetHandleByIndex) {
        nvmlDeviceGetHandleByIndex = (nvml_device_get_handle_by_index_t)dlsym(lib, "nvmlDeviceGetHandleByIndex");
    }

    nvml_device_set_gpc_clk_vf_offset_t nvmlDeviceSetGpcClkVfOffset = 
        (nvml_device_set_gpc_clk_vf_offset_t)dlsym(lib, "nvmlDeviceSetGpcClkVfOffset");
    nvml_device_set_mem_clk_vf_offset_t nvmlDeviceSetMemClkVfOffset = 
        (nvml_device_set_mem_clk_vf_offset_t)dlsym(lib, "nvmlDeviceSetMemClkVfOffset");

    if (!nvmlInit || !nvmlShutdown || !nvmlDeviceGetHandleByIndex || !nvmlDeviceSetGpcClkVfOffset) {
        fprintf(stderr, "Failed to find required NVML symbols\n");
        dlclose(lib);
        return 3;
    }

    int ret = nvmlInit();
    if (ret != 0) {
        fprintf(stderr, "nvmlInit failed with error code %d\n", ret);
        dlclose(lib);
        return 4;
    }

    void *handle = NULL;
    ret = nvmlDeviceGetHandleByIndex(0, &handle);
    if (ret != 0) {
        fprintf(stderr, "nvmlDeviceGetHandleByIndex failed with error code %d\n", ret);
        nvmlShutdown();
        dlclose(lib);
        return 5;
    }

    printf("Setting GPC offset to %d MHz\n", gpc_offset);
    ret = nvmlDeviceSetGpcClkVfOffset(handle, gpc_offset);
    if (ret != 0) {
        fprintf(stderr, "nvmlDeviceSetGpcClkVfOffset failed with error code %d (requires root/privileges)\n", ret);
        nvmlShutdown();
        dlclose(lib);
        return 6;
    }

    if (argc >= 3 && nvmlDeviceSetMemClkVfOffset) {
        printf("Setting Memory offset to %d MHz\n", mem_offset);
        ret = nvmlDeviceSetMemClkVfOffset(handle, mem_offset);
        if (ret != 0) {
            fprintf(stderr, "nvmlDeviceSetMemClkVfOffset failed with error code %d\n", ret);
        }
    }

    nvmlShutdown();
    dlclose(lib);
    printf("Successfully applied GPU clock offsets.\n");
    return 0;
}
