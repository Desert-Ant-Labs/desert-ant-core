import Foundation

/// Bundle accessor for CoreML resources only, so apps do not ship the
/// artifact for the other runtime.
///
/// ```swift
/// import __PRODUCT__CoreMLResources
/// let __MODEL__ = __PRODUCT__(bundle: __PRODUCT__CoreMLResourcesBundle.bundle)
/// ```
public enum __PRODUCT__CoreMLResourcesBundle {
    public static var bundle: Bundle { Bundle.module }
}
