import Foundation

/// Bundle accessor for TFLite resources only, so apps do not ship the
/// artifact for the other runtime.
///
/// ```swift
/// import __PRODUCT__TFLiteResources
/// let __MODEL__ = __PRODUCT__(bundle: __PRODUCT__TFLiteResourcesBundle.bundle)
/// ```
public enum __PRODUCT__TFLiteResourcesBundle {
    public static var bundle: Bundle { Bundle.module }
}
