// SPDX-License-Identifier: AGPL-3.0-only

public struct TemplateAccount: Sendable, Hashable {
    public let name: String
    public let type: AccountType
    public let children: [TemplateAccount]
    public let placeholder: Bool

    public init(
        name: String,
        type: AccountType,
        children: [TemplateAccount] = [],
        placeholder: Bool = false
    ) {
        self.name = name
        self.type = type
        self.children = children
        self.placeholder = placeholder
    }
}

public struct BookTemplate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let roots: [TemplateAccount]
}

public struct FlatTemplateAccount: Sendable, Hashable {
    public let path: String
    public let parentPath: String?
    public let name: String
    public let type: AccountType
    public let placeholder: Bool
}

public enum BookTemplates {
    public static let personal = BookTemplate(
        id: "personal",
        name: "Personal",
        description: "Everyday household accounts.",
        roots: [
            TemplateAccount(name: "Assets", type: .asset, children: [
                TemplateAccount(name: "Bank", type: .bank, children: [
                    TemplateAccount(name: "Checking", type: .bank),
                    TemplateAccount(name: "Savings", type: .bank),
                ]),
                TemplateAccount(name: "Investments", type: .asset, placeholder: true),
            ]),
            TemplateAccount(name: "Liabilities", type: .liability, children: [
                TemplateAccount(name: "Credit Card", type: .credit),
            ]),
            TemplateAccount(name: "Equity", type: .equity, children: [
                TemplateAccount(name: "Opening Balances", type: .equity),
            ]),
            TemplateAccount(name: "Income", type: .income, children: [
                TemplateAccount(name: "Salary", type: .income),
                TemplateAccount(name: "Interest", type: .income),
            ]),
            TemplateAccount(name: "Expenses", type: .expense, children: [
                TemplateAccount(name: "Rent", type: .expense),
                TemplateAccount(name: "Groceries", type: .expense),
                TemplateAccount(name: "Utilities", type: .expense),
            ]),
        ]
    )

    public static let smallBusiness = BookTemplate(
        id: "small-business",
        name: "Small business",
        description: "Sole trader and small-team accounts.",
        roots: [
            TemplateAccount(name: "Assets", type: .asset, children: [
                TemplateAccount(name: "Business Checking", type: .bank),
                TemplateAccount(name: "Accounts Receivable", type: .receivable),
            ]),
            TemplateAccount(name: "Liabilities", type: .liability, children: [
                TemplateAccount(name: "Accounts Payable", type: .payable),
                TemplateAccount(name: "Sales Tax Payable", type: .liability),
            ]),
            TemplateAccount(name: "Equity", type: .equity, children: [
                TemplateAccount(name: "Owner's Equity", type: .equity),
            ]),
            TemplateAccount(name: "Income", type: .income, children: [
                TemplateAccount(name: "Sales", type: .income),
                TemplateAccount(name: "Services", type: .income),
            ]),
            TemplateAccount(name: "Expenses", type: .expense, children: [
                TemplateAccount(name: "Payroll", type: .expense),
                TemplateAccount(name: "Rent", type: .expense),
                TemplateAccount(name: "Supplies", type: .expense),
                TemplateAccount(name: "Software", type: .expense),
            ]),
        ]
    )

    public static let insuranceAgency = BookTemplate(
        id: "insurance-agency",
        name: "Insurance agency",
        description: "Premium trust, commissions and agency overhead.",
        roots: [
            TemplateAccount(name: "Assets", type: .asset, children: [
                TemplateAccount(name: "Trust", type: .bank, children: [
                    TemplateAccount(name: "Premium Trust", type: .bank),
                    TemplateAccount(name: "Operating", type: .bank),
                ]),
                TemplateAccount(name: "Commissions Receivable", type: .receivable),
            ]),
            TemplateAccount(name: "Liabilities", type: .liability, children: [
                TemplateAccount(name: "Commissions Payable", type: .payable),
                TemplateAccount(name: "Premiums Payable", type: .payable),
            ]),
            TemplateAccount(name: "Equity", type: .equity, children: [
                TemplateAccount(name: "Owner's Equity", type: .equity),
            ]),
            TemplateAccount(name: "Income", type: .income, children: [
                TemplateAccount(name: "Commissions", type: .income),
                TemplateAccount(name: "Policy Fees", type: .income),
            ]),
            TemplateAccount(name: "Expenses", type: .expense, children: [
                TemplateAccount(name: "E&O Insurance", type: .expense),
                TemplateAccount(name: "Licensing", type: .expense),
                TemplateAccount(name: "Office", type: .expense),
                TemplateAccount(name: "Marketing", type: .expense),
            ]),
        ]
    )

    public static let all = [personal, smallBusiness, insuranceAgency]

    public static func by(id: String?) -> BookTemplate {
        all.first { $0.id == id } ?? personal
    }

    public static func flatten(_ template: BookTemplate) -> [FlatTemplateAccount] {
        var rows: [FlatTemplateAccount] = []
        func visit(_ account: TemplateAccount, parent: String?) {
            let path = parent.map { "\($0)/\(account.name)" } ?? account.name
            rows.append(FlatTemplateAccount(
                path: path,
                parentPath: parent,
                name: account.name,
                type: account.type,
                placeholder: account.placeholder
            ))
            for child in account.children { visit(child, parent: path) }
        }
        for root in template.roots { visit(root, parent: nil) }
        return rows
    }
}
