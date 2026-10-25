// Meyrin Virtual Mic (MeyrinMic): the virtual microphone for 美玲's Mac-only meeting interpretation
// (docs/meiling-soft-design.md §4.1). An AudioServerPlugIn built on libASPL (MIT).
//
// Two devices share one ring buffer inside coreaudiod, so no IPC is needed:
//   "Meyrin Virtual Mic"       input only, visible: the meeting app picks it as its microphone
//   "Meyrin Virtual Mic Feed"  output only, hidden: AISM plays the translated voice into it (found by UID)
// Both run at 48 kHz mono Float32 on the same host clock, so the ring needs no resampling. One writer (the feed
// device's IO thread) and one reader (the mic's IO thread): the writer only moves the write position, the reader
// only moves the read position and skips ahead when it falls behind (latency stays bounded, never blocks).

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannels = 1;
constexpr UInt64 kRingFrames = 1 << 16;  // ~1.37 s
constexpr UInt64 kMaxLagFrames = 4800;   // reader more than 100 ms behind: skip ahead...
constexpr UInt64 kTargetLagFrames = 960; // ...to 20 ms behind the writer

class Ring
{
public:
    void Write(const Float32* frames, UInt32 count)
    {
        UInt64 w = write_.load(std::memory_order_relaxed);
        for (UInt32 i = 0; i < count; i++) {
            buffer_[(w + i) & (kRingFrames - 1)] = frames[i];
        }
        write_.store(w + count, std::memory_order_release);
    }

    // Fills `count` frames. Playback starts once 20 ms are queued (the two sides use different IO buffer sizes);
    // an underrun plays what is left, then silence, and waits for 20 ms again.
    void Read(Float32* out, UInt32 count)
    {
        const UInt64 w = write_.load(std::memory_order_acquire);
        UInt64 r = read_.load(std::memory_order_relaxed);
        if (w - r > kMaxLagFrames) {
            r = w - kTargetLagFrames;
        }
        if (!primed_ && w - r >= kTargetLagFrames) {
            primed_ = true;
        }
        const UInt64 n = primed_ ? std::min<UInt64>(w - r, count) : 0;
        if (n < count) {
            primed_ = false;
        }
        for (UInt64 i = 0; i < n; i++) {
            out[i] = buffer_[(r + i) & (kRingFrames - 1)];
        }
        std::memset(out + n, 0, (count - n) * sizeof(Float32));
        read_.store(r + n, std::memory_order_relaxed);
    }

private:
    Float32 buffer_[kRingFrames] = {};
    std::atomic<UInt64> write_{0}, read_{0};
    bool primed_ = false;  // reader-only
};

class FeedHandler : public aspl::IORequestHandler
{
public:
    explicit FeedHandler(std::shared_ptr<Ring> ring)
        : ring_(std::move(ring))
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        ring_->Write(static_cast<const Float32*>(bytes), bytesCount / sizeof(Float32) / kChannels);
    }

private:
    std::shared_ptr<Ring> ring_;
};

class MicHandler : public aspl::IORequestHandler
{
public:
    explicit MicHandler(std::shared_ptr<Ring> ring)
        : ring_(std::move(ring))
    {
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        ring_->Read(static_cast<Float32*>(bytes), bytesCount / sizeof(Float32) / kChannels);
    }

private:
    std::shared_ptr<Ring> ring_;
};

aspl::StreamParameters StreamParams(aspl::Direction direction)
{
    aspl::StreamParameters params;
    params.Direction = direction;
    params.Format = {
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = sizeof(Float32) * kChannels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(Float32) * kChannels,
        .mChannelsPerFrame = kChannels,
        .mBitsPerChannel = 32,
    };
    return params;
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();
    auto ring = std::make_shared<Ring>();

    aspl::DeviceParameters micParams;
    micParams.Name = "Meyrin Virtual Mic";
    micParams.Manufacturer = "AISM";
    micParams.DeviceUID = "MeyrinMic_UID";
    micParams.ModelUID = "MeyrinMic_Model";
    micParams.SampleRate = kSampleRate;
    micParams.ChannelCount = kChannels;
    micParams.CanBeDefault = true;  // some meeting apps only use the default input
    micParams.CanBeDefaultForSystemSounds = false;
    auto mic = std::make_shared<aspl::Device>(context, micParams);
    mic->AddStreamAsync(StreamParams(aspl::Direction::Input));
    mic->SetIOHandler(std::make_shared<MicHandler>(ring));

    aspl::DeviceParameters feedParams;
    feedParams.Name = "Meyrin Virtual Mic Feed";
    feedParams.Manufacturer = "AISM";
    feedParams.DeviceUID = "MeyrinMicFeed_UID";
    feedParams.ModelUID = "MeyrinMic_Model";
    feedParams.SampleRate = kSampleRate;
    feedParams.ChannelCount = kChannels;
    feedParams.CanBeDefault = false;
    feedParams.CanBeDefaultForSystemSounds = false;
    auto feed = std::make_shared<aspl::Device>(context, feedParams);
    feed->AddStreamAsync(StreamParams(aspl::Direction::Output));
    feed->SetIOHandler(std::make_shared<FeedHandler>(ring));
    feed->SetIsHidden(true);  // not in any device menu; AISM opens it by UID

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(mic);
    plugin->AddDevice(feed);
    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* MeyrinMicEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
