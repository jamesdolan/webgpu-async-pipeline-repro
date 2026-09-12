#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>

constexpr NSUInteger kPipelineCount = 100;
constexpr NSUInteger kRounds = 64;

static double Milliseconds() {
    return NSProcessInfo.processInfo.systemUptime * 1000.0;
}

static void Require(bool condition, NSString* message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static NSString* Shader(NSArray<NSNumber*>* constants) {
    NSMutableString* source = [NSMutableString stringWithString:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vertexMain(uint i [[vertex_id]]) {\n"
        "  const float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
        "  return float4(p[i],0,1);\n}\n"];
    for (NSUInteger index = 0; index < 4; ++index) {
        [source appendFormat:@"constant uint s%lu = %uu;\n", index, constants[index].unsignedIntValue];
    }
    [source appendString:@"fragment uint4 fragmentMain(float4 p [[position]]) {\n"
        "  uint x = uint(p.x) + s0, y = s1, z = s2, w = s3;\n"];
    for (NSUInteger round = 0; round < kRounds; ++round) {
        [source appendFormat:@"x = (x ^ (y >> 7u)) * 1664525u + s%lu;\n"
            "y = (y ^ (z >> 9u)) * 22695477u + s%lu;\n"
            "z = (z ^ (w >> 13u)) * 1103515245u + s%lu;\n"
            "w = (w ^ (x >> 11u)) * 214013u + s%lu;\n",
            round % 4, (round + 1) % 4, (round + 2) % 4, (round + 3) % 4];
    }
    [source appendString:@"return uint4(x,y,z,w);\n}\n"];
    return source;
}

static double DrawAndValidate(id<MTLCommandQueue> queue, NSArray* pipelines,
                             id<MTLTexture> texture, NSArray<NSArray<NSNumber*>*>* constants) {
    const double start = Milliseconds();
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    for (NSUInteger index = 0; index < kPipelineCount; ++index) {
        [encoder setRenderPipelineState:pipelines[index]];
        [encoder setScissorRect:MTLScissorRect{.x = index, .y = 0, .width = 1, .height = 1}];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    Require(commands.status == MTLCommandBufferStatusCompleted, commands.error.description);
    uint32_t actual[kPipelineCount * 4] = {};
    [texture getBytes:actual bytesPerRow:sizeof(actual)
          fromRegion:MTLRegionMake2D(0, 0, kPipelineCount, 1) mipmapLevel:0];
    const double elapsed = Milliseconds() - start;
    for (NSUInteger index = 0; index < kPipelineCount; ++index) {
        NSArray<NSNumber*>* values = constants[index];
        uint32_t x = values[0].unsignedIntValue + index;
        uint32_t y = values[1].unsignedIntValue;
        uint32_t z = values[2].unsignedIntValue;
        uint32_t w = values[3].unsignedIntValue;
        for (NSUInteger round = 0; round < kRounds; ++round) {
            x = (x ^ (y >> 7u)) * 1664525u + values[round % 4].unsignedIntValue;
            y = (y ^ (z >> 9u)) * 22695477u + values[(round + 1) % 4].unsignedIntValue;
            z = (z ^ (w >> 13u)) * 1103515245u + values[(round + 2) % 4].unsignedIntValue;
            w = (w ^ (x >> 11u)) * 214013u + values[(round + 3) % 4].unsignedIntValue;
        }
        Require(actual[index * 4] == x && actual[index * 4 + 1] == y &&
                actual[index * 4 + 2] == z && actual[index * 4 + 3] == w,
                [NSString stringWithFormat:@"Output mismatch at pipeline %lu", index]);
    }
    return elapsed;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Require(device != nil, @"No Metal device");
        NSMutableArray* constants = [NSMutableArray array];
        NSMutableArray* sources = [NSMutableArray array];
        NSMutableArray* libraries = [NSMutableArray array];
        NSMutableArray* pipelines = [NSMutableArray array];
        for (NSUInteger index = 0; index < kPipelineCount; ++index) {
            uint32_t values[4] = {};
            arc4random_buf(values, sizeof(values));
            NSArray* entry = @[@(values[0]), @(values[1]), @(values[2]), @(values[3])];
            [constants addObject:entry];
            [sources addObject:Shader(entry)];
            [libraries addObject:NSNull.null];
            [pipelines addObject:NSNull.null];
        }
        dispatch_group_t group = dispatch_group_create();
        const double start = Milliseconds();
        for (NSUInteger index = 0; index < kPipelineCount; ++index) {
            dispatch_group_enter(group);
            [device newLibraryWithSource:sources[index] options:nil
                completionHandler:^(id<MTLLibrary> library, NSError* error) {
                    Require(library != nil, error.description);
                    @synchronized(libraries) {
                        libraries[index] = library;
                    }
                    dispatch_group_leave(group);
                }];
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        const double libraryMs = Milliseconds() - start;
        const double pipelineStart = Milliseconds();
        for (NSUInteger index = 0; index < kPipelineCount; ++index) {
            id<MTLLibrary> library = libraries[index];
            MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = [library newFunctionWithName:@"vertexMain"];
            descriptor.fragmentFunction = [library newFunctionWithName:@"fragmentMain"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
            dispatch_group_enter(group);
            [device newRenderPipelineStateWithDescriptor:descriptor
                completionHandler:^(id<MTLRenderPipelineState> pipeline, NSError* error) {
                    Require(pipeline != nil, error.description);
                    @synchronized(pipelines) {
                        pipelines[index] = pipeline;
                    }
                    dispatch_group_leave(group);
                }];
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        const double pipelineMs = Milliseconds() - pipelineStart;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint
            width:kPipelineCount height:1 mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        Require(queue != nil && texture != nil, @"Resource allocation failed");
        const double firstUseMs = DrawAndValidate(queue, pipelines, texture, constants);
        const double secondUseMs = DrawAndValidate(queue, pipelines, texture, constants);
        NSDictionary* result = @{@"device": device.name,
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"pipelineCount": @(kPipelineCount), @"rounds": @(kRounds),
            @"libraryMs": @(libraryMs), @"pipelineMs": @(pipelineMs),
            @"firstUseMs": @(firstUseMs), @"secondUseMs": @(secondUseMs),
            @"validatedValues": @(kPipelineCount * 4 * 2), @"constants": constants};
        NSError* error = nil;
        NSData* json = [NSJSONSerialization dataWithJSONObject:result
            options:NSJSONWritingPrettyPrinted error:&error];
        Require(json != nil, error.description);
        [NSFileHandle.fileHandleWithStandardOutput writeData:json];
        fputs("\n", stdout);
    }
}
