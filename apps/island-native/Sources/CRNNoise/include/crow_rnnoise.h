#ifndef CROW_RNNOISE_H
#define CROW_RNNOISE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CrowRNNoiseProcessor CrowRNNoiseProcessor;

CrowRNNoiseProcessor *crow_rnnoise_create(void);
void crow_rnnoise_destroy(CrowRNNoiseProcessor *processor);
int crow_rnnoise_frame_size(void);
float crow_rnnoise_process_frame(CrowRNNoiseProcessor *processor, float *out, const float *in);

#ifdef __cplusplus
}
#endif

#endif
