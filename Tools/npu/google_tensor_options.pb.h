// Stand-in for the protoc-generated header, hand-rolling proto3 wire format
// so the plugin builds without libprotobuf. Only what compiler_plugin.cc
// touches exists: the setters, two getters, the enums, and serialization.
// Proto3 semantics: fields at their default value emit nothing.
#ifndef LITERT_VENDORS_GOOGLE_TENSOR_COMPILER_GOOGLE_TENSOR_OPTIONS_PB_H_
#define LITERT_VENDORS_GOOGLE_TENSOR_COMPILER_GOOGLE_TENSOR_OPTIONS_PB_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace third_party::odml::litert::litert::vendors::google_tensor::compiler {

enum GoogleTensorOptionsTruncationType : int {
  FLOAT_TRUNCATION_TYPE_AUTO = 0,
  FLOAT_TRUNCATION_TYPE_NO_TRUNCATION = 1,
  FLOAT_TRUNCATION_TYPE_BFLOAT16 = 2,
  FLOAT_TRUNCATION_TYPE_HALF = 3,
};

enum GoogleTensorOptionsShardingIntensity : int {
  SHARDING_INTENSITY_UNSPECIFIED = 0,
  SHARDING_INTENSITY_MINIMAL = 1,
  SHARDING_INTENSITY_MODERATE = 2,
  SHARDING_INTENSITY_EXTENSIVE = 3,
  SHARDING_INTENSITY_MAXIMUM = 4,
};

enum DeviceType : int {
  DEVICE_TYPE_UNSPECIFIED = 0,
  DEVICE_TYPE_TENSOR_G3 = 1,
  DEVICE_TYPE_TENSOR_G4 = 2,
  DEVICE_TYPE_TENSOR_G5 = 3,
  DEVICE_TYPE_TENSOR_G6 = 4,
  DEVICE_TYPE_TENSOR_G7 = 5,
};

namespace pbwire {
inline void PutVarint(std::string* out, uint64_t v) {
  while (v >= 0x80) { out->push_back(static_cast<char>(v | 0x80)); v >>= 7; }
  out->push_back(static_cast<char>(v));
}
inline void PutTag(std::string* out, int field, int wire) {
  PutVarint(out, static_cast<uint64_t>((field << 3) | wire));
}
inline void PutVarintField(std::string* out, int field, uint64_t v) {
  if (v == 0) return;
  PutTag(out, field, 0);
  PutVarint(out, v);
}
inline void PutStringField(std::string* out, int field, const std::string& s) {
  if (s.empty()) return;
  PutTag(out, field, 2);
  PutVarint(out, s.size());
  out->append(s);
}
}  // namespace pbwire

class GoogleTensorCompilerConfig {
 public:
  enum CompilationClient : int {
    COMPILATION_CLIENT_UNSPECIFIED = 0,
    COMPILATION_CLIENT_LITERT_PLUGIN = 1,
    COMPILATION_CLIENT_SDK = 2,
  };
  void set_compilation_client(CompilationClient c) { compilation_client_ = c; }
  void set_device(DeviceType d) { device_ = d; }
  void set_litert_version(std::string v) { litert_version_ = std::move(v); }

  std::string SerializeAsString() const {
    std::string out;
    pbwire::PutVarintField(&out, 1, compilation_client_);
    pbwire::PutVarintField(&out, 2, device_);
    pbwire::PutStringField(&out, 3, litert_version_);
    return out;
  }

 private:
  int compilation_client_ = 0;
  int device_ = 0;
  std::string litert_version_;
};

class OpFilter {
 public:
  const std::string& op_name_pattern() const { return op_name_pattern_; }
  void set_op_name_pattern(std::string p) { op_name_pattern_ = std::move(p); }

 private:
  std::string op_name_pattern_;
};

class OpFilters {
 public:
  enum FilterBehavior : int {
    MATCHES_NOT_RUN_ON_TPU = 0,
    MATCHES_RUN_ON_TPU = 1,
  };
  FilterBehavior filter_behavior() const { return filter_behavior_; }
  const std::vector<OpFilter>& filters() const { return filters_; }

 private:
  FilterBehavior filter_behavior_ = MATCHES_NOT_RUN_ON_TPU;
  std::vector<OpFilter> filters_;
};

class GoogleTensorOptions {
 public:
  void set_float_truncation_type(GoogleTensorOptionsTruncationType t) {
    float_truncation_type_ = t;
  }
  void set_int64_to_int32_truncation(bool v) { int64_to_int32_truncation_ = v; }
  void set_output_dir(std::string v) { output_dir_ = std::move(v); }
  void set_dump_op_timings(bool v) { dump_op_timings_ = v; }
  void set_enable_large_model_support(bool v) { enable_large_model_support_ = v; }
  void set_enable_four_bit_compilation(bool v) { enable_four_bit_compilation_ = v; }
  void set_sharding_intensity(GoogleTensorOptionsShardingIntensity s) {
    sharding_intensity_ = s;
  }
  void set_enable_dynamic_range_quantization(bool v) {
    enable_dynamic_range_quantization_ = v;
  }
  void set_op_filters_proto(std::string v) { op_filters_proto_ = std::move(v); }
  void set_extra_options_path(std::string v) { extra_options_path_ = std::move(v); }
  void set_extra_options(std::string v) { extra_options_ = std::move(v); }
  GoogleTensorCompilerConfig* mutable_compiler_config() { return &compiler_config_; }

  const std::string& op_filters_proto() const { return op_filters_proto_; }
  const std::string& extra_options_path() const { return extra_options_path_; }
  const std::string& extra_options() const { return extra_options_; }

  bool SerializeToString(std::string* out) const {
    out->clear();
    pbwire::PutVarintField(out, 1, float_truncation_type_);
    pbwire::PutVarintField(out, 2, int64_to_int32_truncation_ ? 1 : 0);
    pbwire::PutStringField(out, 3, output_dir_);
    pbwire::PutVarintField(out, 4, dump_op_timings_ ? 1 : 0);
    pbwire::PutVarintField(out, 5, enable_large_model_support_ ? 1 : 0);
    pbwire::PutVarintField(out, 6, enable_four_bit_compilation_ ? 1 : 0);
    pbwire::PutVarintField(out, 7, sharding_intensity_);
    pbwire::PutStringField(out, 9, compiler_config_.SerializeAsString());
    pbwire::PutVarintField(out, 10, enable_dynamic_range_quantization_ ? 1 : 0);
    pbwire::PutStringField(out, 11, op_filters_proto_);
    pbwire::PutStringField(out, 12, extra_options_path_);
    pbwire::PutStringField(out, 13, extra_options_);
    return true;
  }
  std::string SerializeAsString() const {
    std::string out;
    SerializeToString(&out);
    return out;
  }

 private:
  int float_truncation_type_ = 0;
  bool int64_to_int32_truncation_ = false;
  std::string output_dir_;
  bool dump_op_timings_ = false;
  bool enable_large_model_support_ = false;
  bool enable_four_bit_compilation_ = false;
  int sharding_intensity_ = 0;
  GoogleTensorCompilerConfig compiler_config_;
  bool enable_dynamic_range_quantization_ = false;
  std::string op_filters_proto_;
  std::string extra_options_path_;
  std::string extra_options_;
};

}  // namespace third_party::odml::litert::litert::vendors::google_tensor::compiler

#endif  // LITERT_VENDORS_GOOGLE_TENSOR_COMPILER_GOOGLE_TENSOR_OPTIONS_PB_H_
