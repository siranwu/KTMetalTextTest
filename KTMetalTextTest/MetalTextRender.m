//
//  MetalTextRender.m
//  KTMetalTextTest
//
//  Created by tu jinqiu on 2018/12/4.
//  Copyright © 2018年 tu jinqiu. All rights reserved.
//

#import "MetalTextRender.h"
#import "MetalTextHeader.h"
#import <GLKit/GLKit.h>
#import "MetalTextMesh.h"

static const NSUInteger kMaxBuffersInFlight = 3;

static inline matrix_float4x4 s_getMatrixFloat4x4FromGlMatrix4(GLKMatrix4 glMatrix4)
{
    matrix_float4x4 ret = (matrix_float4x4){
        simd_make_float4(glMatrix4.m00, glMatrix4.m01, glMatrix4.m02, glMatrix4.m03),
        simd_make_float4(glMatrix4.m10, glMatrix4.m11, glMatrix4.m12, glMatrix4.m13),
        simd_make_float4(glMatrix4.m20, glMatrix4.m21, glMatrix4.m22, glMatrix4.m23),
        simd_make_float4(glMatrix4.m30, glMatrix4.m31, glMatrix4.m32, glMatrix4.m33),
    };
    return ret;
}

@interface MetalTextRender ()
{
    MetalUniforms _uniforms;
    matrix_float4x4 _projectionMatrix;
}

@property(nonatomic, weak) MTKView *mtkView;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> renderPipelineState;
@property(nonatomic, strong) id<MTLBuffer> uniformsBuffer;

@property(nonatomic, strong) dispatch_semaphore_t frameBoundarySemaphore;

@property(nonatomic, strong) MTKMesh *textMesh;

@end

@implementation MetalTextRender

- (instancetype)initWithMTKView:(MTKView *)mtkView
{
    if (self = [super init]) {
        _mtkView = mtkView;
        mtkView.delegate = self;
        _device = mtkView.device;
        _frameBoundarySemaphore = dispatch_semaphore_create(kMaxBuffersInFlight);
        mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        [self p_setupVertexDescriptor];
        [self p_buildPipeline];
        [self p_setupBuffers];
    }
    
    return self;
}

- (void)p_setupVertexDescriptor
{
    _vertexDescriptor = [MDLVertexDescriptor new];
    _vertexDescriptor.attributes[0].format = MDLVertexFormatFloat2;
    _vertexDescriptor.attributes[0].offset = 0;
    _vertexDescriptor.attributes[0].bufferIndex = 0;
    _vertexDescriptor.attributes[0].name = MDLVertexAttributePosition;
    _vertexDescriptor.attributes[1].format = MDLVertexFormatFloat4;
    _vertexDescriptor.attributes[1].offset = sizeof(float) * 2;
    _vertexDescriptor.attributes[1].bufferIndex = 0;
    _vertexDescriptor.attributes[1].name = MDLVertexAttributeColor;
    _vertexDescriptor.layouts[0].stride = sizeof(float) * 6;
}

- (void)p_buildPipeline
{
    self.commandQueue = [self.device newCommandQueue];
    
    id<MTLLibrary> library = [self.device newDefaultLibrary];
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_func"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_func"];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    [descriptor setSampleCount:self.mtkView.sampleCount];
    [descriptor setVertexFunction:vertexFunc];
    [descriptor setFragmentFunction:fragmentFunc];
    [descriptor setVertexDescriptor:MTKMetalVertexDescriptorFromModelIO(self.vertexDescriptor)];
    descriptor.colorAttachments[0].pixelFormat = self.mtkView.colorPixelFormat;
    descriptor.depthAttachmentPixelFormat = self.mtkView.depthStencilPixelFormat;
    descriptor.stencilAttachmentPixelFormat = self.mtkView.depthStencilPixelFormat;
    
    NSError *error = nil;
    self.renderPipelineState = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (error) {
        NSLog(@"build pipeline error");
    }
}

- (void)p_setupBuffers
{
    MTKMeshBufferAllocator *bufferAllocator = [[MTKMeshBufferAllocator alloc] initWithDevice:self.device];
    UIFont *font = [UIFont fontWithName:@"HoeflerText-Black" size:72];
    MTKMesh *textMesh = [MetalTextMesh meshWithString:@"测试数据"
                                                 font:font
                                                color:[UIColor redColor]
                                     vertexDescriptor:self.vertexDescriptor
                                      bufferAllocator:bufferAllocator];
    self.textMesh = textMesh;
    
    matrix_float4x4 modelViewMatrix = s_getMatrixFloat4x4FromGlMatrix4(GLKMatrix4MakeScale(0.015, 0.015, 0.015));
    _uniforms.mvpMatrix = matrix_multiply(_projectionMatrix, modelViewMatrix);
    self.uniformsBuffer = [self.device newBufferWithBytes:&_uniforms length:sizeof(MetalUniforms) options:MTLResourceStorageModeShared];
}

- (void)p_updateUniforms
{
    matrix_float4x4 modelViewMatrix = s_getMatrixFloat4x4FromGlMatrix4(GLKMatrix4MakeScale(0.015, 0.015, 0.015));
    _uniforms.mvpMatrix = matrix_multiply(_projectionMatrix, modelViewMatrix);
    void *contents = [self.uniformsBuffer contents];
    memcpy(contents, &_uniforms, sizeof(MetalUniforms));
}

- (void)p_render
{
    dispatch_semaphore_wait(self.frameBoundarySemaphore, DISPATCH_TIME_FOREVER);
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t block_sema = _frameBoundarySemaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
    
    [self p_updateUniforms];
    
    MTLRenderPassDescriptor* renderPassDescriptor = self.mtkView.currentRenderPassDescriptor;
    if(renderPassDescriptor != nil) {
        id <MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeBack];
        [renderEncoder setRenderPipelineState:self.renderPipelineState];
        [renderEncoder setTriangleFillMode:MTLTriangleFillModeLines];
        
        [renderEncoder setVertexBuffer:self.uniformsBuffer offset:0 atIndex:MetalBufferIndexUniforms];
        int i = 0;
        for (MTKMeshBuffer *vertexBuffer in self.textMesh.vertexBuffers) {
            if ([vertexBuffer isKindOfClass:[MTKMeshBuffer class]]) {
                [renderEncoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:MetalBufferIndexVertex + i];
                i++;
            }
        }
        
        for(MTKSubmesh *submesh in self.textMesh.submeshes) {
            [renderEncoder drawIndexedPrimitives:submesh.primitiveType
                                      indexCount:submesh.indexCount
                                       indexType:submesh.indexType
                                     indexBuffer:submesh.indexBuffer.buffer
                               indexBufferOffset:submesh.indexBuffer.offset];
        }
        
        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:self.mtkView.currentDrawable];
    }
    
    [commandBuffer commit];
}

#pragma mark - mtkview delegate

- (void)drawInMTKView:(MTKView *)view
{
    [self p_render];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    float aspect = (float)size.width / (float)size.height;
    GLKMatrix4 matrix = GLKMatrix4MakeScale(1.0, aspect, 1.0);
    _projectionMatrix = s_getMatrixFloat4x4FromGlMatrix4(matrix);
}

@end
