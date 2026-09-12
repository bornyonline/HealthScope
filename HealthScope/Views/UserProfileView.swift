import SwiftUI
import PhotosUI
import ImageIO
import UIKit

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: UserProfileViewModel
    @EnvironmentObject private var preferences: AppPreferences

    @State private var name = ""
    @State private var hasDateOfBirth = false
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var metricHeight = ""
    @State private var imperialFeet = ""
    @State private var imperialInches = ""
    @State private var weight = ""
    @State private var photoData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        UserAvatar(profile: draftProfile, size: 104)

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label(photoData == nil ? "Choose Photo" : "Replace Photo", systemImage: "photo")
                        }

                        if photoData != nil {
                            Button("Remove Photo", role: .destructive) {
                                photoData = nil
                                selectedPhoto = nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Identification") {
                    TextField("Name", text: $name)
                        .textContentType(.name)

                    Toggle("Date of Birth", isOn: $hasDateOfBirth)
                    if hasDateOfBirth {
                        DatePicker(
                            "Birth Date",
                            selection: $dateOfBirth,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                }

                Section("Measurements") {
                    if preferences.measurementSystem == .metric {
                        TextField("Height (cm)", text: $metricHeight)
                            .keyboardType(.decimalPad)
                        TextField("Weight (kg)", text: $weight)
                            .keyboardType(.decimalPad)
                    } else {
                        HStack {
                            TextField("Height (ft)", text: $imperialFeet)
                                .keyboardType(.numberPad)
                            TextField("Height (in)", text: $imperialInches)
                                .keyboardType(.decimalPad)
                        }
                        TextField("Weight (lb)", text: $weight)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Apple Health") {
                    Button {
                        Task {
                            if let imported = await viewModel.importFromHealth(into: draftProfile) {
                                var merged = imported
                                merged.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                merged.photoData = photoData
                                loadProfile(merged)
                            }
                        }
                    } label: {
                        HStack {
                            Label("Refresh from Apple Health", systemImage: "heart.fill")
                            Spacer()
                            if viewModel.isImportingFromHealth {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isImportingFromHealth)

                    Text("Imports the available birth date, latest height, and latest weight. Name and photo stay under your control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = photoError ?? viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(viewModel.isImportingFromHealth)
            .navigationTitle("User Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.save(draftProfile) {
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isImportingFromHealth)
                }
            }
            .onAppear { loadProfile() }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                do {
                    guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                          let processed = Self.downsampledJPEG(data) else {
                        throw UserProfilePhotoError.unreadable
                    }
                    photoData = processed
                    photoError = nil
                } catch is CancellationError {
                    return
                } catch {
                    photoError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private var draftProfile: UserProfile {
        UserProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dateOfBirth: hasDateOfBirth ? dateOfBirth : nil,
            heightCentimeters: parsedHeightCentimeters,
            weightKilograms: parsedWeightKilograms,
            photoData: photoData
        )
    }

    private var parsedHeightCentimeters: Double? {
        if preferences.measurementSystem == .metric {
            return parseLocalizedDecimal(metricHeight) ?? (metricHeight.isEmpty ? nil : .nan)
        }
        guard !imperialFeet.isEmpty || !imperialInches.isEmpty else { return nil }
        guard let feet = parseLocalizedDecimal(imperialFeet),
              let inches = imperialInches.isEmpty ? 0 : parseLocalizedDecimal(imperialInches) else { return .nan }
        return feet * 30.48 + inches * 2.54
    }

    private var parsedWeightKilograms: Double? {
        guard let value = parseLocalizedDecimal(weight) else { return weight.isEmpty ? nil : .nan }
        return preferences.measurementSystem.kilograms(fromDisplayWeight: value)
    }

    private func loadProfile(_ profile: UserProfile? = nil) {
        let profile = profile ?? viewModel.profile
        name = profile.name
        photoData = profile.photoData
        if let birthDate = profile.dateOfBirth {
            hasDateOfBirth = true
            dateOfBirth = birthDate
        } else {
            hasDateOfBirth = false
        }
        loadMeasurements(from: profile)
    }

    private func loadMeasurements(from profile: UserProfile) {
        guard let height = profile.heightCentimeters else {
            metricHeight = ""
            imperialFeet = ""
            imperialInches = ""
            loadWeight(from: profile)
            return
        }

        metricHeight = height.formatted(.number.precision(.fractionLength(0...1)))
        let totalInches = height / 2.54
        let feet = Int(totalInches / 12)
        imperialFeet = String(feet)
        imperialInches = (totalInches - Double(feet * 12))
            .formatted(.number.precision(.fractionLength(0...1)))
        loadWeight(from: profile)
    }

    private func loadWeight(from profile: UserProfile) {
        guard let kilograms = profile.weightKilograms else {
            weight = ""
            return
        }
        weight = preferences.measurementSystem.displayWeight(fromKilograms: kilograms)
            .formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func downsampledJPEG(_ data: Data) -> Data? {
        guard data.count <= 25 * 1_048_576,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }
}

struct UserAvatar: View {
    let profile: UserProfile
    let size: CGFloat

    var body: some View {
        Group {
            if let photoData = profile.photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                ZStack {
                    Color.accentColor.opacity(0.16)
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        profile.name.split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

nonisolated private enum UserProfilePhotoError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "The selected image could not be prepared as a profile photo."
    }
}
