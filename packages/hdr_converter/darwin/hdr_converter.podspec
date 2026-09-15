Pod::Spec.new do |s|
  s.name             = 'hdr_converter'
  s.version          = '0.1.0'
  s.summary          = 'SDR video frame decoder and SDR->HDR still image encoder'
  s.description      = 'Decodes an SDR video frame-by-frame and converts a single SDR image into an HDR (HEIC HLG/PQ) still.'
  s.homepage         = 'https://example.com/hdr_converter'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'hdr' => 'hi.atsumi@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'ImageIO'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
  }
end
