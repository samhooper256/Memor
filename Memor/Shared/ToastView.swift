//
//  ToastView.swift
//  Memor
//
//  Shared toast message + view used by the instance editor and other modal windows.
//

import SwiftUI

struct ToastMessage: Equatable {
    let message: String
    let style: ToastStyle
}

enum ToastStyle {
    case success
    case error
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        Text(toast.message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var backgroundColor: Color {
        switch toast.style {
        case .success:
            return Color.green.opacity(0.95)
        case .error:
            return Color.red.opacity(0.95)
        }
    }
}
