//
//  HLSPlayerView.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 23.10.2024.
//

import UIKit
import Metal
import MetalKit
import CoreMedia

final class HLSPlayerView: UIView {

    enum Constants {
        static let imagePlaneVertexData: [Float] = [
            -1.0, -1.0, 0.0, 1.0,
            1.0, -1.0, 1.0, 1.0,
            -1.0, 1.0, 0.0, 0.0,
            1.0, 1.0, 1.0, 0.0
        ]
    }

    var player: HLSPlayer
    private var videoOutput: HLSVideoOutput

    private var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var metalView: MTKView
    private var imagePlaneVertexBuffer: MTLBuffer?

    private var renderPipelineDescriptor: MTLRenderPipelineDescriptor?
    private var renderPipelineState: MTLRenderPipelineState?

    // MARK: - Life cycle

    init(player: HLSPlayer) {
        self.player = player
        videoOutput = HLSVideoOutput()
        player.add(videoOutput)
        metalView = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        metalView.delegate = self
        addSubview(metalView)
        setupMetal()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
    }

    // MARK: - Public

    func draw(_ buffer: CMSampleBuffer) {
        guard let renderPipelineState,
              let drawable = metalView.currentDrawable,
              let imageBuffer = CMSampleBufferGetImageBuffer(buffer),
              CVPixelBufferGetPlaneCount(imageBuffer) >= 2,
              let textureY = createTexture(fromPixelBuffer: imageBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
              let textureCbCr = createTexture(fromPixelBuffer: imageBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
        else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let buffer = commandQueue?.makeCommandBuffer()
        let encoder = buffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        encoder?.setRenderPipelineState(renderPipelineState)
        encoder?.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: 0)
        encoder?.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: 0)
        encoder?.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: 1)
        encoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        encoder?.endEncoding()

        buffer?.present(drawable)
        buffer?.commit()
    }

    private func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer,
                               pixelFormat: MTLPixelFormat,
                               planeIndex: Int) -> CVMetalTexture? {
        guard let textureCache else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil,
                                                               textureCache,
                                                               pixelBuffer,
                                                               nil,
                                                               pixelFormat,
                                                               width,
                                                               height,
                                                               planeIndex,
                                                               &texture)

        if status != kCVReturnSuccess {
            texture = nil
        }

        return texture
    }

    // MARK: - Private

    private func setupMetal() {
        guard let device else {
            assertionFailure("It is impossible to work with Metal without a MTLDevice.")
            return
        }
        do {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            commandQueue = device.makeCommandQueue()
            metalView.colorPixelFormat = .bgra8Unorm

            let mainBundle = Bundle(for: HLSPlayerView.self)

            let bundle: Bundle
            if let path = mainBundle.path(forResource: "HLSPlayerBundle", ofType: "bundle"),
               let playerBundle = Bundle(path: path) {
                bundle = playerBundle
            }
            else {
                bundle = mainBundle
            }

            let library = try device.makeDefaultLibrary(bundle: bundle)
            let fragmentFunction = library.makeFunction(name: "displayTexture")
            let vertexFunction = library.makeFunction(name: "mapTexture")

            let imagePlaneVertexDescriptor = MTLVertexDescriptor()

            imagePlaneVertexDescriptor.attributes[0].format = .float2
            imagePlaneVertexDescriptor.attributes[0].offset = 0
            imagePlaneVertexDescriptor.attributes[0].bufferIndex = 0

            imagePlaneVertexDescriptor.attributes[1].format = .float2
            imagePlaneVertexDescriptor.attributes[1].offset = 8
            imagePlaneVertexDescriptor.attributes[1].bufferIndex = 0

            imagePlaneVertexDescriptor.layouts[0].stride = 16
            imagePlaneVertexDescriptor.layouts[0].stepRate = 1
            imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
            renderPipelineDescriptor = pipelineDescriptor

            let imagePlaneVertexDataCount = Constants.imagePlaneVertexData.count * MemoryLayout<Float>.size
            imagePlaneVertexBuffer = device.makeBuffer(bytes: Constants.imagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])

            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            print(error)
        }
    }
}

extension HLSPlayerView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {

    }
    
    func draw(in view: MTKView) {
        guard player.playbackState == .playing else {
            return
        }

        let time = videoOutput.videoSampleBufferTime(forHostTime: CACurrentMediaTime())
//        print("HLSPLAYER: attempt draw in \(time.seconds)")
        guard videoOutput.hasNewPixelBuffer(for: time),
              let sampleBuffer = videoOutput.videoSampleBuffer(for: time) else {
            return
        }
//        print("HLSPLAYER: draw in \(time.seconds)")
        draw(sampleBuffer)
    }
}
