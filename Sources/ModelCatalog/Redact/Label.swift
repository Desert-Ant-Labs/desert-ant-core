/// A category of personal information that ``Redact`` can detect.
///
/// The raw value is the stable public label string (e.g. `"GIVEN_NAME"`) used in
/// the default redaction placeholder `[GIVEN_NAME]`.
public enum Label: String, Sendable, Hashable, CaseIterable {
    case givenName = "GIVEN_NAME"
    case surname = "SURNAME"
    case streetName = "STREET_NAME"
    case buildingNumber = "BUILDING_NUMBER"
    case secondaryAddress = "SECONDARY_ADDRESS"
    case city = "CITY"
    case state = "STATE"
    case zipCode = "ZIP_CODE"
    case email = "EMAIL"
    case phone = "PHONE"
    case creditCard = "CREDIT_CARD"
    case bankAccount = "BANK_ACCOUNT"
    case routingNumber = "ROUTING_NUMBER"
    case ipAddress = "IP_ADDRESS"
    case url = "URL"
    case governmentID = "GOVERNMENT_ID"
    case passport = "PASSPORT"
    case driversLicense = "DRIVERS_LICENSE"
    case taxID = "TAX_ID"
    case ssn = "SSN"
    case imei = "IMEI"

    /// A short, human-readable name for this category.
    public var displayName: String {
        switch self {
        case .givenName: "Given name"
        case .surname: "Surname"
        case .streetName: "Street"
        case .buildingNumber: "Building number"
        case .secondaryAddress: "Unit / apartment"
        case .city: "City"
        case .state: "State / region"
        case .zipCode: "Postal code"
        case .email: "Email"
        case .phone: "Phone"
        case .creditCard: "Credit card"
        case .bankAccount: "Bank account"
        case .routingNumber: "Routing number"
        case .ipAddress: "IP address"
        case .url: "URL"
        case .governmentID: "Government ID"
        case .passport: "Passport"
        case .driversLicense: "Driver's license"
        case .taxID: "Tax ID"
        case .ssn: "SSN"
        case .imei: "IMEI"
        }
    }

    /// Name-family labels (given name / surname).
    static let nameFamilies: Set<String> = ["GIVEN_NAME", "SURNAME"]
}
