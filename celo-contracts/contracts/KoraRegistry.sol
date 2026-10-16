// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title  KoraRegistry
/// @notice Central registry for vets, pets, and medical records on the Kora App platform.
/// @dev    Inherits OpenZeppelin Pausable for emergency-stop functionality.
contract KoraRegistry is Pausable {
    // -------------------------------------------------------------------------
    // Constants — string length limits (issue #919)
    // -------------------------------------------------------------------------

    /// @notice Maximum byte length for short string fields (name, species, breed, birthday).
    uint256 public constant MAX_SHORT_LEN = 64;

    /// @notice Maximum byte length for long string fields (diagnosis, treatment, notes).
    uint256 public constant MAX_LONG_LEN  = 1000;

    /// @notice Maximum number of records scanned/returned in date-range query when limit is omitted.
    uint256 public constant MAX_QUERY_LIMIT = 100;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Address of the contract administrator.
    address public admin;

    /// @notice Category of a medical record.
    enum RecordType { Checkup, Vaccination, Surgery, LabResult, Other }

    /// @notice Registered veterinarian.
    /// @param vetAddress     On-chain address of the vet.
    /// @param licenseNumber  Vet's professional licence number (original casing).
    /// @param specialization Vet's area of specialization.
    /// @param isVerified     True when the admin has verified the vet.
    /// @param isRevoked      True when the admin has revoked the vet's access.
    struct Vet {
        address vetAddress;
        string  licenseNumber;
        string  specialization;
        bool    isVerified;
        bool    isRevoked;
    }

    /// @notice Registered pet.
    /// @param petId   Unique identifier assigned at registration.
    /// @param owner   Current owner's address.
    /// @param name    Pet's name.
    /// @param species Species (e.g. "Dog", "Cat").
    /// @param breed   Breed descriptor.
    /// @param birthday Date of birth string.
    /// @param active  False when the pet has been deactivated.
    /// @param pendingOwner Proposed recipient awaiting acceptance.
    struct Pet {
        uint256 petId;
        address owner;
        string  name;
        string  species;
        string  breed;
        string  birthday;
        bool    active;
        address pendingOwner;
    }

    /// @notice A single medical record entry for a pet.
    /// @param recordId   Unique record identifier.
    /// @param petId      Pet this record belongs to.
    /// @param vet        Address of the vet who created the record.
    /// @param recordType Category of the record.
    /// @param diagnosis  Diagnosis text.
    /// @param treatment  Treatment text.
    /// @param notes      Additional notes (may be empty).
    /// @param timestamp  Block timestamp at time of creation.
    struct MedicalRecord {
        uint256 recordId;
        uint256 petId;
        address vet;
        RecordType recordType;
        string  diagnosis;
        string  treatment;
        string  notes;
        uint256 timestamp;
    }

    uint256 private _petCounter;
    uint256 private _recordCounter;
    uint256 private _vetCount;

    mapping(address => Vet)      public vets;
    mapping(uint256 => Pet)      public pets;
    mapping(uint256 => MedicalRecord[]) private _petRecords;
    mapping(address => uint256[]) private _ownerPets;
    mapping(uint256 => uint256) private _recordPet;   // recordId => petId
    mapping(uint256 => uint256) private _recordIndex; // recordId => index in _petRecords[petId]
    mapping(bytes32 => address)  private _licenseToVet;

    // Ordered list of all ever-registered vet addresses (issue #926)
    address[] private _vetAddresses;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new vet registers.
    /// @param vet           Address of the registering vet.
    /// @param licenseNumber Licence number supplied at registration.
    event VetRegistered(address indexed vet, string licenseNumber);

    /// @notice Emitted when a vet updates their specialization.
    /// @param vet            Address of the vet.
    /// @param specialization New specialization string.
    event VetSpecializationUpdated(address indexed vet, string specialization);

    /// @notice Emitted when the admin verifies a vet.
    /// @param vet Address of the verified vet.
    event VetVerified(address indexed vet);

    /// @notice Emitted when the admin revokes a vet.
    /// @param vet Address of the revoked vet.
    event VetRevoked(address indexed vet);

    /// @notice Emitted when a new pet is registered.
    /// @param petId ID assigned to the new pet.
    /// @param owner Address of the registering owner.
    event PetRegistered(uint256 indexed petId, address indexed owner);

    /// @notice Emitted when a pet is deactivated.
    /// @param petId ID of the deactivated pet.
    event PetDeactivated(uint256 indexed petId);

    /// @notice Emitted when a previously deactivated pet is reactivated.
    /// @param petId ID of the reactivated pet.
    event PetReactivated(uint256 indexed petId);

    /// @notice Emitted when a medical record is added for a pet.
    /// @param petId    ID of the pet.
    /// @param recordId ID assigned to the new record.
    /// @param vet      Address of the vet who added the record.
    event MedicalRecordAdded(uint256 indexed petId, uint256 indexed recordId, address indexed vet);
    /// @notice Emitted when a medical record is corrected.
    /// @dev    The original field values are preserved in the event log for full auditability.
    /// @param recordId         ID of the corrected record.
    /// @param petId            Pet the record belongs to.
    /// @param correctedBy      Address that performed the correction.
    /// @param originalDiagnosis Previous diagnosis text.
    /// @param originalTreatment Previous treatment text.
    /// @param originalNotes     Previous notes text.
    /// @param newDiagnosis      Updated diagnosis text.
    /// @param newTreatment      Updated treatment text.
    /// @param newNotes          Updated notes text.
    event MedicalRecordCorrected(
        uint256 indexed recordId,
        uint256 indexed petId,
        address indexed correctedBy,
        string  originalDiagnosis,
        string  originalTreatment,
        string  originalNotes,
        string  newDiagnosis,
        string  newTreatment,
        string  newNotes
    );

    /// @notice Emitted when the admin role is transferred.
    /// @param previousAdmin The outgoing admin address.
    /// @param newAdmin      The incoming admin address.
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferProposed(address indexed currentAdmin, address indexed pendingAdmin);

    event PetTransferInitiated(uint256 indexed petId, address indexed from, address indexed to);
    event PetTransferAccepted(uint256 indexed petId, address indexed from, address indexed to);
    event PetTransferCancelled(uint256 indexed petId, address indexed owner, address indexed pendingOwner);

    address public pendingAdmin;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "KoraRegistry: not admin");
        _;
    }

    modifier onlyPetOwner(uint256 petId) {
        require(pets[petId].owner != address(0), "KoraRegistry: pet does not exist");
        require(pets[petId].owner == msg.sender, "KoraRegistry: not pet owner");
        _;
    }

    // -------------------------------------------------------------------------
    // Vet functions
    // -------------------------------------------------------------------------

    /// @notice Registers the caller as a veterinarian.
    /// @param licenseNumber  Professional licence number (must be unique).
    /// @param specialization Area of specialization.
    function registerVet(string calldata licenseNumber, string calldata specialization) external whenNotPaused {
        require(vets[msg.sender].vetAddress == address(0), "KoraRegistry: vet already registered");
        require(bytes(licenseNumber).length > 0, "KoraRegistry: license required");
        require(bytes(licenseNumber).length <= MAX_SHORT_LEN, "KoraRegistry: license too long");
        require(bytes(specialization).length <= MAX_SHORT_LEN, "KoraRegistry: specialization too long");

        bytes32 licenseKey = keccak256(bytes(licenseNumber));
        require(_licenseToVet[licenseKey] == address(0), "KoraRegistry: license already registered");

        vets[msg.sender] = Vet({
            vetAddress: msg.sender,
            licenseNumber: licenseNumber,
            specialization: specialization,
            isVerified: false,
            isRevoked: false
        });
        _licenseToVet[licenseKey] = msg.sender;
        _vetAddresses.push(msg.sender);
        _vetCount++;

        emit VetRegistered(msg.sender, licenseNumber);
    }

    /// @notice Updates the caller's specialization.
    /// @param specialization New specialization string.
    function updateVetSpecialization(string calldata specialization) external whenNotPaused {
        require(vets[msg.sender].vetAddress != address(0), "KoraRegistry: vet not registered");
        require(!vets[msg.sender].isRevoked, "KoraRegistry: vet is revoked");
        require(bytes(specialization).length <= MAX_SHORT_LEN, "KoraRegistry: specialization too long");

        vets[msg.sender].specialization = specialization;
        emit VetSpecializationUpdated(msg.sender, specialization);
    }

    /// @notice Marks a registered vet as verified.
    /// @param vet Address of the vet to verify.
    function verifyVet(address vet) external onlyAdmin whenNotPaused {
        require(vets[vet].vetAddress != address(0), "KoraRegistry: vet not registered");
        require(!vets[vet].isRevoked, "KoraRegistry: vet is revoked");
        vets[vet].isVerified = true;
        emit VetVerified(vet);
    }

    /// @notice Revokes a registered vet's access.
    /// @param vet Address of the vet to revoke.
    function revokeVet(address vet) external onlyAdmin whenNotPaused {
        require(vets[vet].vetAddress != address(0), "KoraRegistry: vet not registered");
        vets[vet].isRevoked = true;
        vets[vet].isVerified = false;
        emit VetRevoked(vet);
    }

    /// @notice Returns the total number of vets ever registered.
    function vetCount() external view returns (uint256) {
        return _vetCount;
    }

    /// @notice Returns the address of a vet at a given index in the registration list.
    /// @param index Index into the ordered vet address list.
    function vetAddressAt(uint256 index) external view returns (address) {
        return _vetAddresses[index];
    }

    // -------------------------------------------------------------------------
    // Pet functions
    // -------------------------------------------------------------------------

    /// @notice Registers a new pet owned by the caller.
    /// @param name     Pet's name.
    /// @param species  Species (e.g. "Dog").
    /// @param breed    Breed descriptor.
    /// @param birthday Date of birth string.
    /// @return petId   The newly assigned pet ID.
    function registerPet(
        string calldata name,
        string calldata species,
        string calldata breed,
        string calldata birthday
    ) external whenNotPaused returns (uint256 petId) {
        require(bytes(name).length > 0, "KoraRegistry: name required");
        require(bytes(name).length <= MAX_SHORT_LEN, "KoraRegistry: name too long");
        require(bytes(species).length <= MAX_SHORT_LEN, "KoraRegistry: species too long");
        require(bytes(breed).length <= MAX_SHORT_LEN, "KoraRegistry: breed too long");
        require(bytes(birthday).length <= MAX_SHORT_LEN, "KoraRegistry: birthday too long");

        _petCounter++;
        petId = _petCounter;

        pets[petId] = Pet({
            petId: petId,
            owner: msg.sender,
            name: name,
            species: species,
            breed: breed,
            birthday: birthday,
            active: true,
            pendingOwner: address(0)
        });
        _ownerPets[msg.sender].push(petId);

        emit PetRegistered(petId, msg.sender);
    }

    /// @notice Deactivates a pet owned by the caller.
    /// @param petId ID of the pet to deactivate.
    function deactivatePet(uint256 petId) external onlyPetOwner(petId) whenNotPaused {
        require(pets[petId].active, "KoraRegistry: pet already inactive");
        pets[petId].active = false;
        emit PetDeactivated(petId);
    }

    /// @notice Reactivates a previously deactivated pet owned by the caller.
    /// @param petId ID of the pet to reactivate.
    function reactivatePet(uint256 petId) external onlyPetOwner(petId) whenNotPaused {
        require(!pets[petId].active, "KoraRegistry: pet already active");
        pets[petId].active = true;
        emit PetReactivated(petId);
    }

    /// @notice Returns all pet IDs owned by an address.
    /// @param owner Address to query.
    function getPetsByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerPets[owner];
    }

    // -------------------------------------------------------------------------
    // Medical record functions
    // -------------------------------------------------------------------------

    /// @notice Adds a medical record for a pet. Caller must be a verified, non-revoked vet.
    /// @param petId      Pet the record belongs to.
    /// @param recordType Category of the record.
    /// @param diagnosis  Diagnosis text.
    /// @param treatment  Treatment text.
    /// @param notes      Additional notes (may be empty).
    /// @return recordId  The newly assigned record ID.
    function addMedicalRecord(
        uint256 petId,
        RecordType recordType,
        string calldata diagnosis,
        string calldata treatment,
        string calldata notes
    ) external whenNotPaused returns (uint256 recordId) {
        require(vets[msg.sender].vetAddress != address(0), "KoraRegistry: vet not registered");
        require(vets[msg.sender].isVerified, "KoraRegistry: vet not verified");
        require(!vets[msg.sender].isRevoked, "KoraRegistry: vet is revoked");
        require(pets[petId].owner != address(0), "KoraRegistry: pet does not exist");
        require(bytes(diagnosis).length > 0, "KoraRegistry: diagnosis required");
        require(bytes(diagnosis).length <= MAX_LONG_LEN, "KoraRegistry: diagnosis too long");
        require(bytes(treatment).length <= MAX_LONG_LEN, "KoraRegistry: treatment too long");
        require(bytes(notes).length <= MAX_LONG_LEN, "KoraRegistry: notes too long");

        _recordCounter++;
        recordId = _recordCounter;

        MedicalRecord memory record = MedicalRecord({
            recordId: recordId,
            petId: petId,
            vet: msg.sender,
            recordType: recordType,
            diagnosis: diagnosis,
            treatment: treatment,
            notes: notes,
            timestamp: block.timestamp
        });

        _petRecords[petId].push(record);
        _recordPet[recordId] = petId;
        _recordIndex[recordId] = _petRecords[petId].length - 1;

        emit MedicalRecordAdded(petId, recordId, msg.sender);
    }

    /// @notice Returns all medical records for a pet.
    /// @param petId ID of the pet.
    function getMedicalRecords(uint256 petId) external view returns (MedicalRecord[] memory) {
        return _petRecords[petId];
    }

    /// @notice Returns the number of medical records for a pet.
    /// @param petId ID of the pet.
    function getMedicalRecordCount(uint256 petId) external view returns (uint256) {
        return _petRecords[petId].length;
    }

    /// @notice Corrects an existing medical record. Caller must be the original vet or the admin.
    /// @param recordId     ID of the record to correct.
    /// @param diagnosis    Updated diagnosis text.
    /// @param treatment    Updated treatment text.
    /// @param notes        Updated notes text.
    function correctMedicalRecord(
        uint256 recordId,
        string calldata diagnosis,
        string calldata treatment,
        string calldata notes
    ) external whenNotPaused {
        uint256 petId = _recordPet[recordId];
        require(petId != 0, "KoraRegistry: record does not exist");

        uint256 index = _recordIndex[recordId];
        MedicalRecord storage record = _petRecords[petId][index];

        require(
            msg.sender == record.vet || msg.sender == admin,
            "KoraRegistry: not authorized to correct"
        );
        require(bytes(diagnosis).length > 0, "KoraRegistry: diagnosis required");
        require(bytes(diagnosis).length <= MAX_LONG_LEN, "KoraRegistry: diagnosis too long");
        require(bytes(treatment).length <= MAX_LONG_LEN, "KoraRegistry: treatment too long");
        require(bytes(notes).length <= MAX_LONG_LEN, "KoraRegistry: notes too long");

        emit MedicalRecordCorrected(
            recordId,
            petId,
            msg.sender,
            record.diagnosis,
            record.treatment,
            record.notes,
            diagnosis,
            treatment,
            notes
        );

        record.diagnosis = diagnosis;
        record.treatment = treatment;
        record.notes = notes;
    }

    // -------------------------------------------------------------------------
    // Pet transfer functions
    // -------------------------------------------------------------------------

    /// @notice Initiates transfer of a pet to a new owner.
    /// @param petId   ID of the pet to transfer.
    /// @param newOwner Address of the proposed new owner.
    function initiatePetTransfer(uint256 petId, address newOwner) external onlyPetOwner(petId) whenNotPaused {
        require(newOwner != address(0), "KoraRegistry: invalid new owner");
        require(newOwner != msg.sender, "KoraRegistry: cannot transfer to self");
        pets[petId].pendingOwner = newOwner;
        emit PetTransferInitiated(petId, msg.sender, newOwner);
    }

    /// @notice Accepts a pending pet transfer. Caller must be the pending owner.
    /// @param petId ID of the pet to accept.
    function acceptPetTransfer(uint256 petId) external whenNotPaused {
        require(pets[petId].owner != address(0), "KoraRegistry: pet does not exist");
        require(pets[petId].pendingOwner == msg.sender, "KoraRegistry: not pending owner");

        address previousOwner = pets[petId].owner;
        pets[petId].owner = msg.sender;
        pets[petId].pendingOwner = address(0);

        _ownerPets[msg.sender].push(petId);

        emit PetTransferAccepted(petId, previousOwner, msg.sender);
    }

    /// @notice Cancels a pending pet transfer. Caller must be the current owner.
    /// @param petId ID of the pet.
    function cancelPetTransfer(uint256 petId) external onlyPetOwner(petId) whenNotPaused {
        address pendingOwner = pets[petId].pendingOwner;
        require(pendingOwner != address(0), "KoraRegistry: no pending transfer");
        pets[petId].pendingOwner = address(0);
        emit PetTransferCancelled(petId, msg.sender, pendingOwner);
    }

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @notice Proposes a new admin. The new admin must accept the role.
    /// @param newAdmin Address of the proposed admin.
    function proposeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "KoraRegistry: invalid admin");
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(msg.sender, newAdmin);
    }

    /// @notice Accepts the admin role. Caller must be the pending admin.
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "KoraRegistry: not pending admin");
        address previousAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previousAdmin, msg.sender);
    }

    /// @notice Pauses the contract. Only callable by the admin.
    function pause() external onlyAdmin {
        _pause();
    }

    /// @notice Unpauses the contract. Only callable by the admin.
    function unpause() external onlyAdmin {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the registry with the caller as the initial admin.
    constructor() {
        admin = msg.sender;
    }
}
