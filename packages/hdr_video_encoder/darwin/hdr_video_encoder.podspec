Pod::Spec.new do |s|
  s.name             = 'hdr_video_encoder'
  s.version          = '0.1.0'
  s.summary          = 'HDR HEVC Main10 video encoder for the lyrics app'
  s.description      = 'Encodes raw RGBA frames + an HDR boost mask to an HDR HEVC Main10 mp4.'
  s.homepage         = 'https://example.com/hdr_video_encoder'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'lyrics' => 'hi.atsumi@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'VideoToolbox'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
  }
end
