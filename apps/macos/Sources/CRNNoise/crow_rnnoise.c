#include "crow_rnnoise.h"
#include "rnnoise.h"
#include <stdlib.h>

struct CrowRNNoiseProcessor {
    DenoiseState *state;
};

CrowRNNoiseProcessor *crow_rnnoise_create(void) {
    CrowRNNoiseProcessor *processor = (CrowRNNoiseProcessor *)calloc(1, sizeof(CrowRNNoiseProcessor));
    if (processor == NULL) {
        return NULL;
    }
    processor->state = rnnoise_create(NULL);
    if (processor->state == NULL) {
        free(processor);
        return NULL;
    }
    return processor;
}

void crow_rnnoise_destroy(CrowRNNoiseProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    if (processor->state != NULL) {
        rnnoise_destroy(processor->state);
    }
    free(processor);
}

int crow_rnnoise_frame_size(void) {
    return rnnoise_get_frame_size();
}

float crow_rnnoise_process_frame(CrowRNNoiseProcessor *processor, float *out, const float *in) {
    if (processor == NULL || processor->state == NULL || out == NULL || in == NULL) {
        return 0.0f;
    }
    return rnnoise_process_frame(processor->state, out, in);
}
