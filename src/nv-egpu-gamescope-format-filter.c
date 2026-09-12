#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <drm_fourcc.h>
#include <drm_mode.h>
#include <xf86drmMode.h>

static bool env_enabled(const char *name)
{
	const char *value = getenv(name);
	if (!value || !*value)
		return false;
	return strcmp(value, "0") != 0 &&
	       strcasecmp(value, "false") != 0 &&
	       strcasecmp(value, "no") != 0 &&
	       strcasecmp(value, "off") != 0;
}

static bool process_allowed(void)
{
	if (env_enabled("NV_EGPU_GAMESCOPE_FORMAT_FILTER_ALLOW_ANY"))
		return true;

	char comm[64] = {0};
	FILE *fp = fopen("/proc/self/comm", "r");
	if (!fp)
		return false;
	bool allowed = fgets(comm, sizeof(comm), fp) &&
		       strncmp(comm, "gamescope", strlen("gamescope")) == 0;
	fclose(fp);
	return allowed;
}

static bool force_8bit(void)
{
	return process_allowed() && env_enabled("NV_EGPU_GAMESCOPE_FORCE_8BIT");
}

static bool force_linear(void)
{
	return process_allowed() && env_enabled("NV_EGPU_GAMESCOPE_FORCE_LINEAR");
}

static bool disable_modifiers(void)
{
	return process_allowed() && env_enabled("NV_EGPU_GAMESCOPE_DISABLE_MODIFIERS");
}

static bool hdmi_reduced_blanking(void)
{
	return process_allowed() && env_enabled("NV_EGPU_GAMESCOPE_HDMI_REDUCED_BLANKING");
}

static int max_nvidia_block_height(void)
{
	if (!process_allowed())
		return -1;

	const char *value = getenv("NV_EGPU_GAMESCOPE_MAX_BLOCK_HEIGHT");
	if (!value || !*value)
		return -1;

	char *end = NULL;
	long parsed = strtol(value, &end, 0);
	if (!end || *end || parsed < 0 || parsed > 15)
		return -1;

	return (int)parsed;
}

static bool trace_enabled(void)
{
	return env_enabled("NV_EGPU_GAMESCOPE_FORMAT_FILTER_TRACE");
}

static bool is_unsafe_rgb_format(uint32_t format)
{
	switch (format) {
	case DRM_FORMAT_XRGB2101010:
	case DRM_FORMAT_ARGB2101010:
	case DRM_FORMAT_XBGR2101010:
	case DRM_FORMAT_ABGR2101010:
		return true;
	default:
		return false;
	}
}

static bool is_nvidia_block_linear_modifier(uint64_t modifier)
{
	return fourcc_mod_get_vendor(modifier) == DRM_FORMAT_MOD_VENDOR_NVIDIA &&
	       (modifier & 0x10) != 0;
}

static bool is_5120x1440_60_hdmia_mode(const drmModeModeInfo *mode)
{
	return mode &&
	       mode->hdisplay == 5120 &&
	       mode->vdisplay == 1440 &&
	       mode->vrefresh >= 59 &&
	       mode->vrefresh <= 60 &&
	       mode->clock >= 480000;
}

static void apply_5120x1440_reduced_blanking(drmModeModeInfo *mode)
{
	if (!is_5120x1440_60_hdmia_mode(mode))
		return;

	if (trace_enabled())
		fprintf(stderr,
			"nv-egpu-gamescope-format-filter: mode %dx%d@%u clock %u/%ux%u -> 469000/5280x1481\n",
			mode->hdisplay, mode->vdisplay, mode->vrefresh, mode->clock,
			mode->htotal, mode->vtotal);

	mode->clock = 469000;
	mode->hsync_start = 5168;
	mode->hsync_end = 5200;
	mode->htotal = 5280;
	mode->vsync_start = 1443;
	mode->vsync_end = 1453;
	mode->vtotal = 1481;
	mode->vrefresh = 60;
	mode->flags &= ~(DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_NHSYNC |
			 DRM_MODE_FLAG_PVSYNC | DRM_MODE_FLAG_NVSYNC);
	mode->flags |= DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_NVSYNC;
	snprintf(mode->name, sizeof(mode->name), "5120x1440");
}

static void filter_connector_modes(drmModeConnectorPtr connector)
{
	if (!hdmi_reduced_blanking() || !connector || !connector->modes)
		return;

	if (connector->connector_type != DRM_MODE_CONNECTOR_HDMIA)
		return;

	for (int i = 0; i < connector->count_modes; i++)
		apply_5120x1440_reduced_blanking(&connector->modes[i]);
}

static bool valid_in_formats_blob(const drmModePropertyBlobRes *blob)
{
	if (!blob || !blob->data)
		return false;
	if (blob->length < sizeof(struct drm_format_modifier_blob))
		return false;

	const struct drm_format_modifier_blob *header = blob->data;
	if (header->version != 1)
		return false;
	if (header->formats_offset < sizeof(*header) ||
	    header->modifiers_offset < sizeof(*header))
		return false;
	if (header->formats_offset % sizeof(uint32_t) != 0 ||
	    header->modifiers_offset % sizeof(uint64_t) != 0)
		return false;

	size_t formats_size = (size_t)header->count_formats * sizeof(uint32_t);
	size_t modifiers_size = (size_t)header->count_modifiers * sizeof(struct drm_format_modifier);
	if ((size_t)header->formats_offset + formats_size > blob->length)
		return false;
	if ((size_t)header->modifiers_offset + modifiers_size > blob->length)
		return false;

	return header->count_formats > 0 && header->count_modifiers > 0;
}

static void filter_plane_formats(drmModePlanePtr plane)
{
	if (!force_8bit() || !plane || !plane->formats)
		return;

	uint32_t kept = 0;
	for (uint32_t i = 0; i < plane->count_formats; i++) {
		if (is_unsafe_rgb_format(plane->formats[i]))
			continue;
		plane->formats[kept++] = plane->formats[i];
	}

	if (kept > 0 && kept != plane->count_formats) {
		if (trace_enabled())
			fprintf(stderr,
				"nv-egpu-gamescope-format-filter: plane %u formats %u -> %u\n",
				plane->plane_id, plane->count_formats, kept);
		plane->count_formats = kept;
	}
}

static drmModePropertyBlobPtr filter_modifier_blob(drmModePropertyBlobPtr blob)
{
	if (trace_enabled() && blob && blob->data && blob->length >= sizeof(struct drm_format_modifier_blob)) {
		const struct drm_format_modifier_blob *header = blob->data;
		fprintf(stderr,
			"nv-egpu-gamescope-format-filter: blob %u len=%u version=%u formats=%u@%u modifiers=%u@%u\n",
			blob->id, blob->length, header->version, header->count_formats,
			header->formats_offset, header->count_modifiers, header->modifiers_offset);
	}

	int max_block_height = max_nvidia_block_height();
	if ((!force_8bit() && !force_linear() && max_block_height < 0) ||
	    !valid_in_formats_blob(blob))
		return blob;

	drmModePropertyBlobPtr copy = calloc(1, sizeof(*copy));
	if (!copy)
		return blob;

	copy->id = blob->id;
	copy->length = blob->length;
	copy->data = malloc(blob->length);
	if (!copy->data) {
		free(copy);
		return blob;
	}
	memcpy(copy->data, blob->data, blob->length);

	struct drm_format_modifier_blob *header = copy->data;
	uint32_t *formats = (uint32_t *)((uint8_t *)copy->data + header->formats_offset);
	struct drm_format_modifier *mods =
		(struct drm_format_modifier *)((uint8_t *)copy->data + header->modifiers_offset);

	uint32_t kept_mods = 0;
	for (uint32_t i = 0; i < header->count_modifiers; i++) {
		if (force_linear() && mods[i].modifier != DRM_FORMAT_MOD_LINEAR)
			continue;
		if (max_block_height >= 0 &&
		    is_nvidia_block_linear_modifier(mods[i].modifier) &&
		    (int)(mods[i].modifier & 0xf) > max_block_height)
			continue;

		struct drm_format_modifier mod = mods[i];
		mod.formats = 0;
		for (uint32_t bit = 0; bit < 64; bit++) {
			if (!(mods[i].formats & (UINT64_C(1) << bit)))
				continue;
			uint32_t index = mods[i].offset + bit;
			if (index >= header->count_formats)
				continue;
			if (force_8bit() && is_unsafe_rgb_format(formats[index]))
				continue;
			mod.formats |= UINT64_C(1) << bit;
		}

		if (mod.formats)
			mods[kept_mods++] = mod;
	}

	if (kept_mods == 0) {
		free(copy->data);
		free(copy);
		return blob;
	}

	if (trace_enabled())
		fprintf(stderr,
			"nv-egpu-gamescope-format-filter: modifier blob %u modifiers %u -> %u\n",
			blob->id, header->count_modifiers, kept_mods);
	header->count_modifiers = kept_mods;
	return copy;
}

drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id)
{
	static drmModePlanePtr (*real_fn)(int, uint32_t);
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "drmModeGetPlane");

	drmModePlanePtr plane = real_fn ? real_fn(fd, plane_id) : NULL;
	filter_plane_formats(plane);
	return plane;
}

drmModePropertyBlobPtr drmModeGetPropertyBlob(int fd, uint32_t blob_id)
{
	static drmModePropertyBlobPtr (*real_fn)(int, uint32_t);
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "drmModeGetPropertyBlob");

	drmModePropertyBlobPtr blob = real_fn ? real_fn(fd, blob_id) : NULL;
	return filter_modifier_blob(blob);
}

drmModeConnectorPtr drmModeGetConnector(int fd, uint32_t connector_id)
{
	static drmModeConnectorPtr (*real_fn)(int, uint32_t);
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "drmModeGetConnector");

	drmModeConnectorPtr connector = real_fn ? real_fn(fd, connector_id) : NULL;
	filter_connector_modes(connector);
	return connector;
}

drmModeConnectorPtr drmModeGetConnectorCurrent(int fd, uint32_t connector_id)
{
	static drmModeConnectorPtr (*real_fn)(int, uint32_t);
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "drmModeGetConnectorCurrent");

	drmModeConnectorPtr connector = real_fn ? real_fn(fd, connector_id) : NULL;
	filter_connector_modes(connector);
	return connector;
}

int drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	static int (*real_fn)(int, uint64_t, uint64_t *);
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "drmGetCap");

	int ret = real_fn ? real_fn(fd, capability, value) : -1;
	if (ret == 0 && capability == DRM_CAP_ADDFB2_MODIFIERS && disable_modifiers()) {
		if (trace_enabled())
			fprintf(stderr,
				"nv-egpu-gamescope-format-filter: hiding ADDFB2_MODIFIERS\n");
		*value = 0;
	}
	return ret;
}
