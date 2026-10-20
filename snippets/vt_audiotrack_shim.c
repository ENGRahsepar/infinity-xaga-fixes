/* Minimal C shim: legacy MTK AudioTrack ctor -> Android 17 ctor (codecProvenance='') */
extern void a17_audio_track_ctor(void*, unsigned int, unsigned int, unsigned int, unsigned int,
                                 unsigned long long, unsigned int, void*, int, int, unsigned int,
                                 const void*, const void*, const void*, unsigned char, float, int,
                                 const void*) __asm__(
    "_ZN7android10AudioTrackC1E19audio_stream_type_tj14audio_format_t20audio_channel_mask_t"
    "m20audio_output_flags_tRKNS_2wpINS0_19IAudioTrackCallbackEEEi15audio_session_tNS0_13"
    "transfer_typeEPK20audio_offload_info_tRKNS_7content22AttributionSourceStateEPK18audio_"
    "attributes_tbfiRKNSt3__112basic_stringIcNSM_11char_traitsIcEENSM_9allocatorIcEEEE");

extern void mtk_vt_legacy_audio_track_ctor(void*, unsigned int, unsigned int, unsigned int,
                                           unsigned int, unsigned long long, unsigned int, void*,
                                           int, int, unsigned int, const void*, const void*,
                                           const void*, unsigned char, float, int) __asm__(
    "_ZN7android10AudioTrackC1E19audio_stream_type_tj14audio_format_t20audio_channel_mask_t"
    "m20audio_output_flags_tRKNS_2wpINS0_19IAudioTrackCallbackEEEi15audio_session_tNS0_13"
    "transfer_typeEPK20audio_offload_info_tRKNS_7content22AttributionSourceStateEPK18audio_"
    "attributes_tbfi");

void mtk_vt_legacy_audio_track_ctor(void* self, unsigned int streamType, unsigned int sampleRate,
                                    unsigned int format, unsigned int channelMask,
                                    unsigned long long frameCount, unsigned int flags, void* callback,
                                    int notificationFrames, int session, unsigned int transferType,
                                    const void* offloadInfo, const void* attributionSource,
                                    const void* pAttributes, unsigned char doNotReconnect,
                                    float maxRequiredSpeed, int selectedDeviceId)
{
    /* libc++ std::string SSO layout: {char* data; size_t size; char buf[16]} */
    struct { const void* data; unsigned long long size; char buf[16]; } prov;
    prov.data = prov.buf;
    prov.size = 0;
    prov.buf[0] = 0;
    a17_audio_track_ctor(self, streamType, sampleRate, format, channelMask, frameCount, flags,
                         callback, notificationFrames, session, transferType, offloadInfo,
                         attributionSource, pAttributes, doNotReconnect, maxRequiredSpeed,
                         selectedDeviceId, &prov);
}
