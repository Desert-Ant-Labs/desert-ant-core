// Stand-in for the protoc-generated header. The message holds one optional
// `bytes internal_options = 1` field; hand-rolling the proto3 wire format for
// it (tag 0x0A, varint length, payload) spares the build a libprotobuf
// dependency the plugin uses for nothing else.
#ifndef LITERT_VENDORS_GOOGLE_TENSOR_EDGETPU_COMPILER_OPTIONS_PB_H_
#define LITERT_VENDORS_GOOGLE_TENSOR_EDGETPU_COMPILER_OPTIONS_PB_H_

#include <cstddef>
#include <string>
#include <utility>

namespace litert {
namespace google_tensor {

class EdgeTpuCompilerOptions {
 public:
  void set_internal_options(std::string value) {
    internal_options_ = std::move(value);
  }
  const std::string& internal_options() const { return internal_options_; }

  bool SerializeToString(std::string* out) const {
    out->clear();
    if (internal_options_.empty()) return true;  // empty message: no bytes
    out->push_back('\x0A');
    size_t n = internal_options_.size();
    while (n >= 0x80) {
      out->push_back(static_cast<char>(n | 0x80));
      n >>= 7;
    }
    out->push_back(static_cast<char>(n));
    out->append(internal_options_);
    return true;
  }

 private:
  std::string internal_options_;
};

}  // namespace google_tensor
}  // namespace litert

#endif  // LITERT_VENDORS_GOOGLE_TENSOR_EDGETPU_COMPILER_OPTIONS_PB_H_
