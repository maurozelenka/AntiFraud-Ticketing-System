// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TicketSystemAntiFraud
 * @author Diego (MUniCS - Tecnologías de Registro Distribuido y Blockchain)
 * @notice Versión Avanzada Antifraude: Sistema de billetaje descentralizado con
 *         garantías contra estafas comunes en la reventa (entradas duplicadas,
 *         reventa de entradas usadas, acaparamiento por bots, sobrepagos y transferencias fraudulentas).
 * @dev Implementa mitigación de estafas, liquidación atómica contra entrega (DvP),
 *      devolución de excedentes, límites por monedero, hashes de autenticidad y optimización de gas.
 */
contract TicketSystemAntiFraud {

    // =========================================================================
    // CUSTOM ERRORS (Optimización de Gas y Claridad Semántica)
    // =========================================================================
    error OnlyOrganizerAllowed();
    error OnlyTicketOwnerAllowed();
    error SoldOut();
    error InsufficientPayment(uint256 required, uint256 provided);
    error MaxTicketsPerWalletExceeded(address wallet, uint256 currentCount, uint256 maxAllowed);
    error TicketDoesNotExist(uint256 ticketId);
    error TicketNotForSale(uint256 ticketId);
    error TicketAlreadyUsed(uint256 ticketId);
    error TicketIsFrozen(uint256 ticketId);
    error CannotBuyOwnTicket();
    error PriceExceedsMaxLimit(uint256 proposedPrice, uint256 maxAllowed);
    error InvalidPrice();
    error ResaleWindowClosed(uint256 currentTime, uint256 deadline);
    error TransferFailed();
    error RefundFailed();
    error NoFundsToWithdraw();
    error ReentrancyGuardTriggered();

    // =========================================================================
    // ESTRUCTURA DE DATOS OPTIMIZADA (Struct Packing)
    // =========================================================================
    struct Ticket {
        // --- Slot 1: Total 27 bytes <= 32 bytes (1 solo almacenamiento SSTORE) ---
        address owner;             // 20 bytes: Dirección del titular legal
        bool isUsed;               // 1 byte: Marcada como consumida en puerta
        bool isForSale;            // 1 byte: Disponible para reventa autorizada
        bool isFrozen;             // 1 byte: Congelada por denuncia de fraude/robo
        uint32 ticketId;           // 4 bytes: Identificador de hasta 4.294.967.295 entradas
        // --- Slot 2 ---
        uint256 resalePrice;       // 32 bytes: Precio en Wei fijado para la reventa
        // --- Slot 3 ---
        bytes32 authenticityHash;  // 32 bytes: Hash criptográfico de autenticidad único
    }

    // =========================================================================
    // VARIABLES INMUTABLES Y DE CONFIGURACIÓN
    // =========================================================================
    address public immutable organizer;              // Dirección del organizador del evento
    uint256 public immutable ticketPrice;            // Precio original en taquilla (Wei)
    uint256 public immutable maxMarkupPercentage;    // Margen máximo permitido de reventa (ej. 10%)
    uint256 public immutable maxResalePrice;         // Tope monetario estricto de reventa
    uint256 public immutable totalTickets;           // Aforo máximo total
    uint256 public immutable maxTicketsPerWallet;    // Límite anti-bots/acaparamiento (ej. 2)
    uint256 public immutable resaleDeadline;         // Marca de tiempo límite para revender

    uint256 public ticketsSold;                      // Contador de entradas emitidas
    mapping(uint256 => Ticket) public tickets;       // ticketId => Ficha de la entrada
    mapping(address => uint256) public walletTickets;// Monedero => Número de entradas activas

    // Protección anti-reentrancia sencilla y barata en gas
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // =========================================================================
    // EVENTOS CON INDEXACIÓN
    // =========================================================================
    event TicketMinted(uint256 indexed ticketId, address indexed buyer, bytes32 indexed authenticityHash, uint256 price);
    event TicketListedForResale(uint256 indexed ticketId, address indexed seller, uint256 resalePrice);
    event ResaleCancelled(uint256 indexed ticketId, address indexed seller);
    event ResaleCompleted(uint256 indexed ticketId, address indexed previousOwner, address indexed newOwner, uint256 price, uint256 refundedAmount);
    event TicketValidated(uint256 indexed ticketId, address indexed attendee);
    event TicketFrozen(uint256 indexed ticketId, string reason);
    event TicketUnfrozen(uint256 indexed ticketId);
    event FundsWithdrawn(address indexed organizer, uint256 amount);

    // =========================================================================
    // MODIFICADORES
    // =========================================================================
    modifier onlyOrganizer() {
        if (msg.sender != organizer) revert OnlyOrganizerAllowed();
        _;
    }

    modifier onlyTicketOwner(uint256 _ticketId) {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        if (tickets[_ticketId].owner != msg.sender) revert OnlyTicketOwnerAllowed();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuardTriggered();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================
    /**
     * @notice Despliega el evento con políticas de seguridad y topes antifraude.
     * @param _totalTickets Aforo máximo de entradas.
     * @param _ticketPrice Precio en Wei de cada entrada oficial.
     * @param _maxMarkupPercentage Margen máximo permitido en reventa (ej. 10 para 10%).
     * @param _maxTicketsPerWallet Límite de entradas que puede poseer un mismo monedero.
     * @param _resaleDeadlineTimestamp Fecha y hora UNIX límite para permitir la reventa.
     */
    constructor(
        uint256 _totalTickets,
        uint256 _ticketPrice,
        uint256 _maxMarkupPercentage,
        uint256 _maxTicketsPerWallet,
        uint256 _resaleDeadlineTimestamp
    ) {
        if (_totalTickets == 0 || _ticketPrice == 0 || _maxTicketsPerWallet == 0) revert InvalidPrice();

        organizer = msg.sender;
        totalTickets = _totalTickets;
        ticketPrice = _ticketPrice;
        maxMarkupPercentage = _maxMarkupPercentage;
        maxResalePrice = _ticketPrice + ((_ticketPrice * _maxMarkupPercentage) / 100);
        maxTicketsPerWallet = _maxTicketsPerWallet;
        resaleDeadline = _resaleDeadlineTimestamp;
        _status = _NOT_ENTERED;
    }

    // =========================================================================
    // VENTA PRIMARIA CON CONTROL ANTI-ACAPARAMIENTO Y DEVOLUCIÓN DE EXCESO
    // =========================================================================
    /**
     * @notice Compra de entrada oficial inicial.
     * @dev Si el usuario envía más fondos de los necesarios, el sobrante se devuelve automáticamente.
     *      Verifica que el comprador no supere el aforo ni el límite por cartera.
     * @return ticketId Identificador numérico de la nueva entrada.
     */
    function buyTicket() external payable nonReentrant returns (uint256 ticketId) {
        if (ticketsSold >= totalTickets) revert SoldOut();
        if (msg.value < ticketPrice) revert InsufficientPayment(ticketPrice, msg.value);
        if (walletTickets[msg.sender] >= maxTicketsPerWallet) {
            revert MaxTicketsPerWalletExceeded(msg.sender, walletTickets[msg.sender], maxTicketsPerWallet);
        }

        unchecked {
            ticketId = ++ticketsSold;
            walletTickets[msg.sender]++;
        }

        // Generación de Hash de Autenticidad Criptográfica único para esta entrada
        bytes32 authHash = keccak256(
            abi.encodePacked(ticketId, address(this), block.chainid, msg.sender, block.timestamp)
        );

        tickets[ticketId] = Ticket({
            owner: msg.sender,
            isUsed: false,
            isForSale: false,
            isFrozen: false,
            ticketId: uint32(ticketId),
            resalePrice: 0,
            authenticityHash: authHash
        });

        emit TicketMinted(ticketId, msg.sender, authHash, ticketPrice);

        // Devolución automática de exceso de pago si se envió de más
        uint256 excess = msg.value - ticketPrice;
        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            if (!refunded) revert RefundFailed();
        }
    }

    // =========================================================================
    // REVENTA SEGURA (ANTI-ESCALPADO Y SIN ENTRADAS USADAS/CONGELADAS)
    // =========================================================================
    /**
     * @notice Publica una entrada para reventa verificando que no esté usada, congelada ni fuera de plazo.
     * @param _ticketId ID de la entrada a listar.
     * @param _resalePrice Precio solicitado (debe ser <= maxResalePrice).
     */
    function listTicketForResale(uint256 _ticketId, uint256 _resalePrice) external onlyTicketOwner(_ticketId) {
        Ticket storage ticket = tickets[_ticketId];

        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);
        if (ticket.isFrozen) revert TicketIsFrozen(_ticketId);
        if (block.timestamp > resaleDeadline) revert ResaleWindowClosed(block.timestamp, resaleDeadline);
        if (_resalePrice == 0) revert InvalidPrice();
        if (_resalePrice > maxResalePrice) revert PriceExceedsMaxLimit(_resalePrice, maxResalePrice);

        ticket.isForSale = true;
        ticket.resalePrice = _resalePrice;

        emit TicketListedForResale(_ticketId, msg.sender, _resalePrice);
    }

    /**
     * @notice Cancela la oferta de reventa si el titular decide asistir.
     */
    function cancelResale(uint256 _ticketId) external onlyTicketOwner(_ticketId) {
        Ticket storage ticket = tickets[_ticketId];
        if (!ticket.isForSale) revert TicketNotForSale(_ticketId);

        ticket.isForSale = false;
        ticket.resalePrice = 0;

        emit ResaleCancelled(_ticketId, msg.sender);
    }

    /**
     * @notice Compra de entrada en reventa con liquidación atómica (Delivery vs Payment).
     * @dev Imposible que el vendedor cobre sin entregar la entrada, o que el comprador reciba la entrada sin pagar.
     *      Si se envía más dinero del precio listado, el exceso se reembolsa de inmediato.
     * @param _ticketId ID de la entrada disponible en reventa.
     */
    function buyResaleTicket(uint256 _ticketId) external payable nonReentrant {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);

        Ticket storage ticket = tickets[_ticketId];

        if (!ticket.isForSale) revert TicketNotForSale(_ticketId);
        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);
        if (ticket.isFrozen) revert TicketIsFrozen(_ticketId);
        if (block.timestamp > resaleDeadline) revert ResaleWindowClosed(block.timestamp, resaleDeadline);
        if (msg.sender == ticket.owner) revert CannotBuyOwnTicket();
        if (msg.value < ticket.resalePrice) revert InsufficientPayment(ticket.resalePrice, msg.value);
        if (walletTickets[msg.sender] >= maxTicketsPerWallet) {
            revert MaxTicketsPerWalletExceeded(msg.sender, walletTickets[msg.sender], maxTicketsPerWallet);
        }

        address previousOwner = ticket.owner;
        uint256 agreedPrice = ticket.resalePrice;

        // 1. Modificación de balances y titulares (Checks-Effects)
        walletTickets[previousOwner]--;
        walletTickets[msg.sender]++;

        ticket.owner = msg.sender;
        ticket.isForSale = false;
        ticket.resalePrice = 0;

        // 2. Liquidación atómica: transferencia de fondos al vendedor original
        (bool paidSeller, ) = payable(previousOwner).call{value: agreedPrice}("");
        if (!paidSeller) revert TransferFailed();

        // 3. Devolución automática de exceso al comprador si aportó de más
        uint256 excess = msg.value - agreedPrice;
        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            if (!refunded) revert RefundFailed();
        }

        emit ResaleCompleted(_ticketId, previousOwner, msg.sender, agreedPrice, excess);
    }

    // =========================================================================
    // CONTROL DE ACCESO EN PUERTA
    // =========================================================================
    /**
     * @notice Valida una entrada en el acceso e invalida permanentemente su reutilización.
     * @param _ticketId ID de la entrada a convalidar.
     */
    function validateAccess(uint256 _ticketId) external onlyOrganizer {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);

        Ticket storage ticket = tickets[_ticketId];
        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);
        if (ticket.isFrozen) revert TicketIsFrozen(_ticketId);

        ticket.isUsed = true;
        // Si estaba a la venta, se desactiva inmediatamente
        if (ticket.isForSale) {
            ticket.isForSale = false;
            ticket.resalePrice = 0;
        }

        emit TicketValidated(_ticketId, ticket.owner);
    }

    // =========================================================================
    // HERRAMIENTAS DE SEGURIDAD / CONGELACIÓN POR FRAUDE
    // =========================================================================
    /**
     * @notice Permite al organizador congelar una entrada ante denuncia de estafa o actividad ilícita.
     * @param _ticketId ID de la entrada sospechosa.
     * @param _reason Motivo descriptivo del bloqueo de seguridad.
     */
    function freezeTicket(uint256 _ticketId, string calldata _reason) external onlyOrganizer {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        Ticket storage ticket = tickets[_ticketId];

        ticket.isFrozen = true;
        ticket.isForSale = false;
        ticket.resalePrice = 0;

        emit TicketFrozen(_ticketId, _reason);
    }

    /**
     * @notice Descongela una entrada una vez subsanada la incidencia.
     */
    function unfreezeTicket(uint256 _ticketId) external onlyOrganizer {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        Ticket storage ticket = tickets[_ticketId];

        ticket.isFrozen = false;
        emit TicketUnfrozen(_ticketId);
    }

    // =========================================================================
    // VERIFICACIÓN DE AUTENTICIDAD ON-CHAIN (ANTI-FALSIFICACIONES)
    // =========================================================================
    /**
     * @notice Permite a cualquier comprador o auditor verificar públicamente la autenticidad del ticket.
     * @return isValid Verdadero si existe, no está usada ni congelada.
     * @return currentOwner Dirección del dueño legal registrado.
     * @return forSale Indica si está disponible para compra legal.
     * @return price Precio oficial fijado si está en reventa.
     * @return authHash Hash criptográfico que demuestra su registro original en Ethereum.
     */
    function verifyTicketAuthenticity(uint256 _ticketId) external view returns (
        bool isValid,
        address currentOwner,
        bool forSale,
        uint256 price,
        bytes32 authHash
    ) {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        Ticket storage t = tickets[_ticketId];

        isValid = (!t.isUsed && !t.isFrozen);
        currentOwner = t.owner;
        forSale = t.isForSale;
        price = t.resalePrice;
        authHash = t.authenticityHash;
    }

    // =========================================================================
    // RETIRADA DE FONDOS
    // =========================================================================
    /**
     * @notice El organizador retira los ingresos de la taquilla primaria.
     */
    function withdraw() external onlyOrganizer nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFundsToWithdraw();

        (bool success, ) = payable(organizer).call{value: balance}("");
        if (!success) revert TransferFailed();

        emit FundsWithdrawn(organizer, balance);
    }
}
